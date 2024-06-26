// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// The coarse rasterization stage.

#import config
#import bump
#import drawtag
#import ptcl
#import tile
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> draw_monoids: array<DrawMonoid>;

// TODO: dedup
struct BinHeader {
    element_count: u32,
    chunk_offset: u32,
}

@group(0) @binding(3)
var<storage> bin_headers: array<BinHeader>;

@group(0) @binding(4)
var<storage> info_bin_data: array<u32>;

@group(0) @binding(5)
var<storage> paths: array<Path>;

@group(0) @binding(6)
var<storage> tiles: array<Tile>;

@group(0) @binding(7)
var<storage, read_write> counter: array<i32>;

// Much of this code assumes WG_SIZE == N_TILE. If these diverge, then
// a fair amount of fixup is needed.
let WG_SIZE = 256u;
//let N_SLICE = WG_SIZE / 32u;
let N_SLICE = 8u;
let N_CLIPS = 4u;

var<workgroup> sh_bitmaps: array<array<atomic<u32>, N_TILE>, N_SLICE>;
var<workgroup> sh_part_count: u32;
var<workgroup> sh_part_offsets: u32;
var<workgroup> sh_drawobj_ix: array<u32, WG_SIZE>;
var<workgroup> sh_tile_stride: array<u32, WG_SIZE>;
var<workgroup> sh_tile_width: array<u32, WG_SIZE>;
var<workgroup> sh_tile_x0y0: array<u32, WG_SIZE>;
var<workgroup> sh_tile_count: array<u32, WG_SIZE>;
var<workgroup> sh_tile_base: array<u32, WG_SIZE>;

// Make sure there is space for a command of given size, plus a jump if needed
var<private> last_draw_tag: u32;
var<private> last_tile_ix: u32;
var<private> cmd_offset: u32;
var<private> cmd_limit: u32;
var<private> ptcl_segment_count:i32;

fn alloc_cmd(size: u32) {
    if cmd_offset + size > cmd_limit {
        ptcl_segment_count += 1;
        cmd_offset = 0u;
        cmd_limit = cmd_offset + PTCL_INCREMENT - PTCL_ENDROOM;
        //space for indexing info
        cmd_offset += 1u;
    }
}

@compute @workgroup_size(256)
fn main(
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
    @builtin(global_invocation_id) global_id: vec3<u32>,
) {
    last_tile_ix = 0u;
    cmd_offset = 0u;
    cmd_limit = PTCL_INCREMENT - PTCL_ENDROOM;
    ptcl_segment_count = 0;
    // Exit early if prior stages failed, as we can't run this stage.
    // We need to check only prior stages, as if this stage has failed in another workgroup, 
    // we still want to know this workgroup's memory requirement.   
    let width_in_bins = (config.width_in_tiles + N_TILE_X - 1u) / N_TILE_X;
    let bin_ix = width_in_bins * wg_id.y + wg_id.x;
    var n_partitions = wg_id.z + 1u;//(config.n_drawobj + N_TILE - 1u) / N_TILE;
    // Coordinates of the top left of this bin, in tiles.
    let bin_tile_x = N_TILE_X * wg_id.x;
    let bin_tile_y = N_TILE_Y * wg_id.y;

    let tile_x = local_id.x % N_TILE_X;
    let tile_y = local_id.x / N_TILE_X;
    let this_tile_ix = (bin_tile_y + tile_y) * config.width_in_tiles + bin_tile_x + tile_x + wg_id.z * config.width_in_tiles * config.height_in_tiles;

    var partition_ix = wg_id.z;
    var rd_ix = 0u;
    var wr_ix = 0u;
    var part_start_ix = 0u;
    var ready_ix = 0u;
    
    var zero_contribution = true;

    // blend state
    var clip_count = 0;

    let ptcl_segment_size = i32(PTCL_INCREMENT - PTCL_ENDROOM);

    //we are processing 256 draw_obj at a time cause each bin_header contains info of 256 draw_obj
    ready_ix = 0u;

    //initialize everythings to zero
    for (var i = 0u; i < N_SLICE; i += 1u) {
        atomicStore(&sh_bitmaps[i][local_id.x], 0u);
    }
    let in_ix = partition_ix * N_TILE + bin_ix;
    let bin_header = bin_headers[in_ix];
    sh_part_offsets = config.bin_data_start + bin_header.chunk_offset;
    sh_part_count = bin_header.element_count;
    var tag = DRAWTAG_NOP;
    var drawobj_ix: u32;
    if local_id.x < sh_part_count{
        drawobj_ix = info_bin_data[sh_part_offsets + local_id.x];
        sh_drawobj_ix[local_id.x] = drawobj_ix;
        tag = scene[config.drawtag_base + drawobj_ix];
        // if wg_id.x == 0u && wg_id.y == 0u{
        //     counter[local_id.x] = i32(tag);
        // }
    }

    // At this point, sh_drawobj_ix[0.. sh_part_count] contains merged binning results.
    var tile_count = 0u;
    // I think this predicate is the same as the last, maybe they can be combined
    if tag != DRAWTAG_NOP {
        let path_ix = draw_monoids[drawobj_ix].path_ix;
        let path = paths[path_ix];
        let stride = path.bbox.z - path.bbox.x;
        sh_tile_stride[local_id.x] = stride;
        let dx = i32(path.bbox.x) - i32(bin_tile_x);
        let dy = i32(path.bbox.y) - i32(bin_tile_y);
        let x0 = clamp(dx, 0, i32(N_TILE_X));
        let y0 = clamp(dy, 0, i32(N_TILE_Y));
        let x1 = clamp(i32(path.bbox.z) - i32(bin_tile_x), 0, i32(N_TILE_X));
        let y1 = clamp(i32(path.bbox.w) - i32(bin_tile_y), 0, i32(N_TILE_Y));
        sh_tile_width[local_id.x] = u32(x1 - x0);
        sh_tile_x0y0[local_id.x] = u32(x0) | u32(y0 << 16u);
        tile_count = u32(x1 - x0) * u32(y1 - y0);
        // base relative to bin
        let base = path.tiles - u32(dy * i32(stride) + dx);
        sh_tile_base[local_id.x] = base;
        // TODO: there's a write_tile_alloc here in the source, not sure what it's supposed to do
    }

    // Prefix sum of tile counts
    sh_tile_count[local_id.x] = tile_count;
    for (var i = 0u; i < firstTrailingBit(N_TILE); i += 1u) {
        workgroupBarrier();
        if local_id.x >= (1u << i) {
            tile_count += sh_tile_count[local_id.x - (1u << i)];
        }
        workgroupBarrier();
        sh_tile_count[local_id.x] = tile_count;
    }
    workgroupBarrier();
    let total_tile_count = sh_tile_count[N_TILE - 1u];

    // Parallel iteration over all tiles
    for (var ix = local_id.x; ix < total_tile_count; ix += N_TILE) {
        // Binary search to find draw object which contains this tile
        var el_ix = 0u;
        for (var i = 0u; i < firstTrailingBit(N_TILE); i += 1u) {
            let probe = el_ix + ((N_TILE / 2u) >> i);
            if ix >= sh_tile_count[probe - 1u] {
                el_ix = probe;
            }
        }
        drawobj_ix = sh_drawobj_ix[el_ix];
        tag = scene[config.drawtag_base + drawobj_ix];
        let seq_ix = ix - select(0u, sh_tile_count[el_ix - 1u], el_ix > 0u);
        let width = sh_tile_width[el_ix];
        let x0y0 = sh_tile_x0y0[el_ix];
        let x = (x0y0 & 0xffffu) + seq_ix % width;
        let y = (x0y0 >> 16u) + seq_ix / width;
        let tile_ix = sh_tile_base[el_ix] + sh_tile_stride[el_ix] * y + x;
        let tile = tiles[tile_ix];
        let is_clip = (tag & 1u) != 0u;
        var is_blend = false;
        if is_clip {
            let BLEND_CLIP = (128u << 8u) | 3u;
            let scene_offset = draw_monoids[drawobj_ix].scene_offset;
            let dd = config.drawdata_base + scene_offset;
            let blend = scene[dd];
            is_blend = blend != BLEND_CLIP;
        }
        let include_tile = tile.segments != 0u || (tile.backdrop == 0) == is_clip || is_blend;
        if include_tile {
        let el_slice = el_ix / 32u;
        let el_mask = 1u << (el_ix & 31u);
            atomicOr(&sh_bitmaps[el_slice][y * N_TILE_X + x], el_mask);
        }
    }
    workgroupBarrier();
    // At this point bit drawobj % 32 is set in sh_bitmaps[drawobj / 32][y * N_TILE_X + x]
    // if drawobj touches tile (x, y).
    // Write per-tile command list for this tile
    let within_range = bin_tile_x + tile_x < config.width_in_tiles && bin_tile_y + tile_y < config.height_in_tiles;
    
    if !within_range {
        return;
    }
    //space for indexing info
    cmd_offset += 1u;
   
    var slice_ix = 0u;
    var bitmap = atomicLoad(&sh_bitmaps[0u][local_id.x]);
    while true {
        if bitmap == 0u {
            slice_ix += 1u;
            // potential optimization: make iteration limit dynamic
            if slice_ix == N_SLICE {
                break;
            }
            bitmap = atomicLoad(&sh_bitmaps[slice_ix][local_id.x]);
            if bitmap == 0u {
                continue;
            }
        }
        let el_ix = slice_ix * 32u + firstTrailingBit(bitmap);
        drawobj_ix = sh_drawobj_ix[el_ix];
        // clear LSB of bitmap, using bit magic
        bitmap &= bitmap - 1u;
        let drawtag = scene[config.drawtag_base + drawobj_ix];
        let dm = draw_monoids[drawobj_ix];
        //let is_pattern = dm.pattern_ix % 2u != 0u;
        let dd = config.drawdata_base + dm.scene_offset;
        let di = dm.info_offset;
        if true {
            let tile_ix = sh_tile_base[el_ix] + sh_tile_stride[el_ix] * tile_y + tile_x;
            let tile = tiles[tile_ix];
            zero_contribution = false;
            switch drawtag {
                // DRAWTAG_BEGIN_CLIP
                case 0x9u: {
                    alloc_cmd(2u);
                    cmd_offset += 2u;                  
                    clip_count += 1;
                }
                case 0x1009u:{
                    alloc_cmd(2u);
                    cmd_offset += 2u;                  
                    clip_count += 1;
                }
                // DRAWTAG_END_CLIP
                case 0x21u: {
                    alloc_cmd(2u);
                    cmd_offset += 2u;
                    clip_count -= 1;
                    let blend = scene[dd];
                    let alpha = bitcast<f32>(scene[dd + 1u]);
                    //extract the blend flag
                    let packed_color = unpack4x8unorm(blend).wzyx;
                    // if packed_color.a != 1.0 && layer_counter < MAX_LAYER_COUNT{
                    //     layer_counter += 1u;
                    //     cmd_offset = cmd_limit;
                    // }
                }
                // DRAWTAG_SUPPLEMENT
                case 0x1000u:{

                }
                default: {
                    alloc_cmd(2u);
                    cmd_offset += 2u;
                }
            }
            last_draw_tag = drawtag;
            last_tile_ix = tile_ix;
        }
    }

    let count = ptcl_segment_count + select(0, 1, cmd_offset > 0u);
    counter[this_tile_ix * 3u] = select(count, 0, zero_contribution);
    counter[this_tile_ix * 3u + 1u] = clip_count;
    counter[this_tile_ix * 3u + 2u] = i32(last_tile_ix);
    
}
