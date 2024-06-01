// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Fine rasterizer. This can run in simple (just path rendering) and full
// modes, controllable by #define.
#import tile
#import segment
#import config
#import drawtag
#import transform
#import bump
let MAX_DASHES_ARRAY_SIZE = 20u;

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> tiles: array<Tile>;

@group(0) @binding(3)
var<storage> segments: array<Segment>;

#ifdef full

#import blend
#import ptcl

let GRADIENT_WIDTH = 512;

@group(0) @binding(4)
var<storage> ptcl: array<u32>;

@group(0) @binding(5)
var gradients: texture_2d<f32>;

@group(0) @binding(6)
var<storage> info: array<u32>;

@group(0) @binding(7)
var image_atlas: texture_2d<f32>;

@group(0) @binding(8)
var<storage> draw_monoids: array<DrawMonoid>;

@group(0) @binding(9)
var<storage> clip_path_index: array<u32>;

@group(0) @binding(10)
var<storage> bump: BumpAllocators;

@group(0) @binding(11)
var<storage> fine_index: array<u32>;

@group(0) @binding(12)
var<storage, read_write> fine_slice: array<u32>;

var<private> dashes_array: array<f32,MAX_DASHES_ARRAY_SIZE>;
var<private> dashes_line_length: f32;
var<private> dashes_array_length: u32;

var<private> rgba: array<vec4<f32>, PIXELS_PER_THREAD>;
var<private> blend_stack: array<array<u32, PIXELS_PER_THREAD>, BLEND_STACK_SPLIT>;
var<private> clip_depth: u32;
var<private> area: array<f32, PIXELS_PER_THREAD>;
var<private> temp_area: array<f32, PIXELS_PER_THREAD>;

fn read_dashes_array_from_scene(start:u32, size:u32, length_modifier:f32){
    let length = min(size, MAX_DASHES_ARRAY_SIZE - 1u);
    for (var i = 0u; i < length; i += 1u){
        dashes_array[i] = dashes_line_length;
        let value = bitcast<f32>(scene[config.dasharrays_base + start + i]);
        dashes_line_length += value * length_modifier;
    }
    dashes_array[length] = dashes_line_length;
    dashes_array_length = length + 1u;
}

fn linear_find_index_of_offset(offset:f32) -> u32{
    for (var i = 1u; i < dashes_array_length; i += 1u){
        if dashes_array[i - 1u] < offset && dashes_array[i] >= offset{
            return i;
        }
    }
    return 0u;
}

fn find_next_valid_offset_on_dash_line(optimal:f32) -> f32{
    if(dashes_line_length < 2.0){
        return optimal;
    }
    let base = floor(optimal / dashes_line_length) * dashes_line_length;
    let offset = optimal - base;
    let index = linear_find_index_of_offset(offset);
    let result = base + dashes_array[index];
    return select(optimal, result, index % 2u == 0u);
}

fn find_previous_valid_offset_on_dash_line(optimal:f32) -> f32{
    if(dashes_line_length < 2.0){
        return optimal;
    }
    let base = floor(optimal / dashes_line_length) * dashes_line_length;
    let offset = optimal - base;
    let index = linear_find_index_of_offset(offset);
    let previous_offset = (index - 1u) % dashes_array_length;
    let result = base + dashes_array[previous_offset];
    return select(optimal, result, index % 2u == 0u);
}


fn find_neareset_offset_on_dash_line(optimal:f32, begin:f32, end:f32) -> f32{
    if(dashes_line_length < 2.0){
        return optimal;
    }
    let base = floor(optimal / dashes_line_length) * dashes_line_length;
    let offset = optimal - base;
    let index = linear_find_index_of_offset(offset);
    var previous = base + dashes_array[(index - 1u) % dashes_array_length];
    var next = base + dashes_array[index];
    var opt = clamp(begin, end, optimal);
    previous = max(previous, begin);
    next = min(next,end);
    return select(select(previous, next, abs(next - optimal) < abs(optimal - previous)), optimal, index % 2u == 1u);
}
//dots
fn dummy_array(length_modifier:f32){
    dashes_array_length = 5u;
    dashes_array[0] = 0.0*length_modifier;
    dashes_array[1] = 0.0*length_modifier;
    dashes_array[2] = 20.0*length_modifier;
    dashes_array[3] = 20.0*length_modifier;
    dashes_array[4] = 60.0*length_modifier;
    dashes_line_length = 60.0*length_modifier;
}

fn read_lin_grad(index_mode: u32, info_offset: u32) -> CmdLinGrad{
    let index = index_mode >> 2u;
    let extend_mode = index_mode & 0x3u;
    let line_x = bitcast<f32>(info[info_offset]);
    let line_y = bitcast<f32>(info[info_offset + 1u]);
    let line_c = bitcast<f32>(info[info_offset + 2u]);
    return CmdLinGrad(index, extend_mode, line_x, line_y, line_c);
}

fn read_rad_grad(index_mode: u32, info_offset: u32) -> CmdRadGrad {
    let index = index_mode >> 2u;
    let extend_mode = index_mode & 0x3u;
    let m0 = bitcast<f32>(info[info_offset]);
    let m1 = bitcast<f32>(info[info_offset + 1u]);
    let m2 = bitcast<f32>(info[info_offset + 2u]);
    let m3 = bitcast<f32>(info[info_offset + 3u]);
    let matrx = vec4(m0, m1, m2, m3);
    let xlat = vec2(bitcast<f32>(info[info_offset + 4u]), bitcast<f32>(info[info_offset + 5u]));
    let focal_x = bitcast<f32>(info[info_offset + 6u]);
    let radius = bitcast<f32>(info[info_offset + 7u]);
    let flags_kind = info[info_offset + 8u];
    let flags = flags_kind >> 3u;
    let kind = flags_kind & 0x7u;
    return CmdRadGrad(index, extend_mode, matrx, xlat, focal_x, radius, kind, flags);
}

fn read_image(info_offset: u32) -> CmdImage {
    let m0 = bitcast<f32>(info[info_offset]);
    let m1 = bitcast<f32>(info[info_offset + 1u]);
    let m2 = bitcast<f32>(info[info_offset + 2u]);
    let m3 = bitcast<f32>(info[info_offset + 3u]);
    let matrx = vec4(m0, m1, m2, m3);
    let xlat = vec2(bitcast<f32>(info[info_offset + 4u]), bitcast<f32>(info[info_offset + 5u]));
    let xy = info[info_offset + 6u];
    let width_height = info[info_offset + 7u];
    // The following are not intended to be bitcasts
    let x = f32(xy >> 16u);
    let y = f32(xy & 0xffffu);
    let width = f32(width_height >> 16u);
    let height = f32(width_height & 0xffffu);
    return CmdImage(matrx, xlat, vec2(x, y), vec2(width, height));
}

#else

@group(0) @binding(3)
var output: texture_storage_2d<r8, write>;

#endif

let PIXELS_PER_THREAD = 4u;

fn fill_path(tile: Tile, xy: vec2<f32>, even_odd: bool) -> array<f32, PIXELS_PER_THREAD> {
    var area: array<f32, PIXELS_PER_THREAD>;
    let backdrop_f = f32(tile.backdrop);
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        area[i] = backdrop_f;
    }
    var segment_ix = tile.segments;
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let y = segment.origin.y - xy.y;
        let y0 = clamp(y, 0.0, 1.0);
        let y1 = clamp(y + segment.delta.y, 0.0, 1.0);
        let dy = y0 - y1;
        if dy != 0.0 {
            let vec_y_recip = 1.0 / segment.delta.y;
            let t0 = (y0 - y) * vec_y_recip;
            let t1 = (y1 - y) * vec_y_recip;
            let startx = segment.origin.x - xy.x;
            let x0 = startx + t0 * segment.delta.x;
            let x1 = startx + t1 * segment.delta.x;
            let xmin0 = min(x0, x1);
            let xmax0 = max(x0, x1);
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                let i_f = f32(i);
                let xmin = min(xmin0 - i_f, 1.0) - 1.0e-6;
                let xmax = xmax0 - i_f;
                let b = min(xmax, 1.0);
                let c = max(b, 0.0);
                let d = max(xmin, 0.0);
                let a = (b + 0.5 * (d * d - c * c) - xmin) / (xmax - xmin);
                area[i] += a * dy;
            }
        }
        let y_edge = sign(segment.delta.x) * clamp(xy.y - segment.y_edge + 1.0, 0.0, 1.0);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            area[i] += y_edge;
        }
        segment_ix = segment.next;
    }
    if even_odd {
        // even-odd winding rule
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            let a = area[i];
            area[i] = abs(a - 2.0 * round(0.5 * a));
        }
    } else {
        // non-zero winding rule
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            area[i] = min(abs(area[i]), 1.0);
        }
    }
    return area;
}

fn stroke_path(seg: u32, half_width: f32, xy: vec2<f32>) -> array<f32, PIXELS_PER_THREAD> {
    dashes_line_length = 0.0;  
    var df: array<f32, PIXELS_PER_THREAD>;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        df[i] = 1e9;
    }
    var segment_ix = seg;
    let temp_segment = segments[segment_ix];
    read_dashes_array_from_scene(temp_segment.dash_start, temp_segment.dash_size, temp_segment.dash_modifier);
    //dummy_array(temp_segment.dash_modifier);
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let delta = segment.delta;
        let dpos0 = xy + vec2(0.5, 0.5) - segment.origin;
        let scale = 1.0 / dot(delta, delta);
        let length = length(segment.delta);
        let offset = segment.dash_offset;
        //let offset = 0.0;
        let start = find_next_valid_offset_on_dash_line(offset);
        let end = find_previous_valid_offset_on_dash_line(offset + length);
        //we need this check otherwise curved dash line wrong on the edge
        if end >= start{
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                let dpos = vec2(dpos0.x + f32(i), dpos0.y);
                let t = clamp(dot(dpos, delta) * scale, 0.0, 1.0);
                var optimal = find_neareset_offset_on_dash_line(t * length + offset, start, end) - offset;
                optimal /= length;
                df[i] =  min(df[i], length(delta * optimal - dpos));
                // performance idea: hoist sqrt out of loop
                // let optimal = t*length;
                // let base = floor(optimal / dashes_line_length) * dashes_line_length;
                // let offset = optimal - base;
                // let is_solid = (linear_find_index_of_offset(offset)) % 2u == 1u || segment.dash_array_end == 0u;
                // df[i] =  select(df[i], min(df[i], length(delta * t - dpos)), is_solid);
            }
        }
        segment_ix = segment.next;
    }
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        // reuse array; return alpha rather than distance
        df[i] = clamp(half_width + 0.5 - df[i], 0.0, 1.0);
    }
    return df;
}

fn even_odd_backdrop_draw(tile: Tile) -> bool{
    return abs(tile.backdrop & 1) == 0;
}
fn draw_path(tile: Tile, linewidth: f32, xy:vec2<f32>) -> bool {
    // TODO: take flags
    if linewidth < 0.0 {
        let even_odd = linewidth < -1.0;
        if tile.segments != 0u {
            area = fill_path(tile, xy, even_odd);
            // var current_tile = tile;
            // while current_tile.next_ix != 1 {
            //     area = fill_path(current_tile, xy, even_odd);
            //     // for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            //     //     area[i] = max(area[i], temp_area[i]);
            //     // }
            //     current_tile = tiles[current_tile.next_ix];
            // }
            // area = fill_path(current_tile, xy, even_odd);
        } else {
            if (even_odd && even_odd_backdrop_draw(tile)){
                return false;
            }
            //none zero
            let value = select(1.0, 0.0, tile.segments == 0u && tile.backdrop == 0);
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                area[i] = value;
            }
        }
    } else {
        let stroke = CmdStroke(tile.segments, 0.5 * linewidth);
        area = stroke_path(stroke.tile, stroke.half_width, xy);
    }
    return true;
}

fn extend_mode(t: f32, mode: u32) -> f32 {
    let EXTEND_PAD = 0u;
    let EXTEND_REPEAT = 1u;
    let EXTEND_REFLECT = 2u;
    switch mode {
        // EXTEND_PAD
        case 0u: {
            return clamp(t, 0.0, 1.0);
        }
        // EXTEND_REPEAT
        case 1u: {
            return fract(t);
        }
        // EXTEND_REFLECT
        default: {
            return abs(t - 2.0 * round(0.5 * t));
        }
    }
}

// The X size should be 16 / PIXELS_PER_THREAD
@compute @workgroup_size(4, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    if atomicLoad(&bump.failed) != 0u {
        return;
    }
    clip_depth = 0u;
    let initial_length = config.width_in_tiles * config.height_in_tiles;
    let delta = u32(max(0 ,i32(wg_id.x) - i32(initial_length)));
    var cmd_ix = (wg_id.x - delta) * PTCL_INITIAL_ALLOC + delta * PTCL_INCREMENT; 
    let cmd_end = cmd_ix + select(PTCL_INITIAL_ALLOC, PTCL_INCREMENT, i32(wg_id.x) - i32(initial_length) + 1 > 0);
    //let temp_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    //var cmd_ix = temp_ix * PTCL_INITIAL_ALLOC;
    let indexing = ptcl[cmd_ix];
    cmd_ix += 1u;
    let slice_index = indexing & 0xfffu;
    let begin_clip_count = (indexing >> 12u) & 0xfu;
    let tile_ix = (indexing >> 16u) & 0xffffu;
    let indirect_clip_base = fine_index[tile_ix * 4u + 2u];
    clip_depth = begin_clip_count; 

    //let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;

    let tile_ix_y = tile_ix / config.width_in_tiles;
    let tile_ix_x = tile_ix - tile_ix_y * config.width_in_tiles;
    let xy = vec2(f32(local_id.x * PIXELS_PER_THREAD + tile_ix_x * TILE_WIDTH), f32(local_id.y + tile_ix_y * TILE_HEIGHT));

    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        rgba[i] = unpack4x8unorm(config.base_color).wzyx;
    }
    // main interpretation loop
    while true {
        let value = ptcl[cmd_ix];
        let drawobj_ix = value >> 2u;
        let command = value & 0x3u;        

        if command == CMD_END || cmd_end - cmd_ix < 1u {
            break;
        }

        let tile_ix_or_indirect = ptcl[cmd_ix + 1u];
        cmd_ix += 2u;

        // begin clip do not have a corresponding tile
        if command == CMD_BEGIN_CLIP_DIRECT{
            if clip_depth < BLEND_STACK_SPLIT {
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    blend_stack[clip_depth][i] = pack4x8unorm(rgba[i]);
                    rgba[i] = vec4(0.0);
                }
            } else {
                        // TODO: spill to memory
            }
            clip_depth += 1u;
            continue;
        }

        let tile_ix = select(tile_ix_or_indirect, clip_path_index[tile_ix_or_indirect + indirect_clip_base], command == CMD_DRAW_INDIRECT);
        //could use drawobj_ix to store drawtag directly if we need further expansion
        let drawtag = select(scene[config.drawtag_base + drawobj_ix], 0x21u, command == CMD_DRAW_INDIRECT);
        let dm = draw_monoids[drawobj_ix];
        let dd = config.drawdata_base + dm.scene_offset;
        let di = dm.info_offset;
        let tile = tiles[tile_ix];
        let is_end_clip = drawtag == 0x9u || drawtag == 0x21u;
        let linewidth = select(bitcast<f32>(info[di]), -1.0, is_end_clip);
        if draw_path(tile, linewidth, xy) {
            //End Clips
            if is_end_clip {
                    let blend = scene[dd];
                    let alpha = bitcast<f32>(scene[dd + 1u]);
                    clip_depth -= 1u;
                    var filter_color = unpack4x8unorm(blend).wzyx;
                    filter_color.w = 1.0;
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        var bg_rgba: u32;
                        if clip_depth < BLEND_STACK_SPLIT {
                            bg_rgba = blend_stack[clip_depth][i];
                        } else {
                        // load from memory
                        }
                        let bg = unpack4x8unorm(bg_rgba);
                        //We need to do layer alpha in compose.
                        let fg = rgba[i] * filter_color * area[i];
                    
                        rgba[i] = blend_mix_compose(bg, fg, blend);
                    }
            }

            switch drawtag {
                // CMD_COLOR
                case 0x44u: {
                    let color = scene[dd];
                    let fg = unpack4x8unorm(color).wzyx;
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        let fg_i = fg * area[i];
                        rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                    }
                }
                // CMD_LIN_GRAD
                case 0x114u: {
                    let index = scene[dd];
                    let info_offset = di + 1u;
                    let lin = read_lin_grad(index, info_offset);
                    let d = lin.line_x * xy.x + lin.line_y * xy.y + lin.line_c;
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        let my_d = d + lin.line_x * f32(i);
                        let x = i32(round(extend_mode(my_d, lin.extend_mode) * f32(GRADIENT_WIDTH - 1)));
                        let fg_rgba = textureLoad(gradients, vec2(x, i32(lin.index)), 0);
                        let fg_i = fg_rgba * area[i];
                        rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                    }
                }
                // CMD_RAD_GRAD
                case 0x29cu: {
                    let index = scene[dd];
                    let info_offset = di + 1u;
                    let rad = read_rad_grad(index, info_offset);
                    let focal_x = rad.focal_x;
                    let radius = rad.radius;
                    let is_strip = rad.kind == RAD_GRAD_KIND_STRIP;
                    let is_circular = rad.kind == RAD_GRAD_KIND_CIRCULAR;
                    let is_focal_on_circle = rad.kind == RAD_GRAD_KIND_FOCAL_ON_CIRCLE;
                    let is_swapped = (rad.flags & RAD_GRAD_SWAPPED) != 0u;
                    let r1_recip = select(1.0 / radius, 0.0, is_circular);
                    let less_scale = select(1.0, -1.0, is_swapped || (1.0 - focal_x) < 0.0);
                    let t_sign = sign(1.0 - focal_x);
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        let my_xy = vec2(xy.x + f32(i), xy.y);
                        let local_xy = rad.matrx.xy * my_xy.x + rad.matrx.zw * my_xy.y + rad.xlat;
                        let x = local_xy.x;
                        let y = local_xy.y;
                        let xx = x * x;
                        let yy = y * y;
                        var t = 0.0;
                        var is_valid = true;
                        if is_strip {
                            let a = radius - yy;
                            t = sqrt(a) + x;
                            is_valid = a >= 0.0;
                        } else if is_focal_on_circle {
                            t = (xx + yy) / x;
                            is_valid = t >= 0.0 && x != 0.0;
                        } else if radius > 1.0 {
                            t = sqrt(xx + yy) - x * r1_recip;
                        } else { // radius < 1.0
                            let a = xx - yy;
                            t = less_scale * sqrt(a) - x * r1_recip;
                            is_valid = a >= 0.0 && t >= 0.0;
                        }
                        if is_valid {
                            t = extend_mode(focal_x + t_sign * t, rad.extend_mode);
                            t = select(t, 1.0 - t, is_swapped);
                            let x = i32(round(t * f32(GRADIENT_WIDTH - 1)));
                            let fg_rgba = textureLoad(gradients, vec2(x, i32(rad.index)), 0);
                            let fg_i = fg_rgba * area[i];
                            rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                        }
                    }
                }
                // CMD_IMAGE
                case 0x248u: {
                    let image = read_image(di + 1u);
                    let atlas_extents = image.atlas_offset + image.extents;
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        let my_xy = vec2(xy.x + f32(i), xy.y);
                        let atlas_uv = image.matrx.xy * my_xy.x + image.matrx.zw * my_xy.y + image.xlat + image.atlas_offset;
                        // This currently clips to the image bounds. TODO: extend modes
                        if all(atlas_uv < atlas_extents) && area[i] != 0.0 {
                            let uv_quad = vec4(max(floor(atlas_uv), image.atlas_offset), min(ceil(atlas_uv), atlas_extents));
                            let uv_frac = fract(atlas_uv);
                            let a = premul_alpha(textureLoad(image_atlas, vec2<i32>(uv_quad.xy), 0));
                            let b = premul_alpha(textureLoad(image_atlas, vec2<i32>(uv_quad.xw), 0));
                            let c = premul_alpha(textureLoad(image_atlas, vec2<i32>(uv_quad.zy), 0));
                            let d = premul_alpha(textureLoad(image_atlas, vec2<i32>(uv_quad.zw), 0));
                            let fg_rgba = mix(mix(a, b, uv_frac.y), mix(c, d, uv_frac.y), uv_frac.x);
                            let fg_i = fg_rgba * area[i];
                            rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                        }
                    }
                }
                default:{
                    
                }
            }
        }   
    }
    let xy_uint = vec2<u32>(xy);

    let start_index = fine_index[tile_ix * 4u];
    let slice_buf_index = start_index + slice_index;
    let slice_buf_index_base = slice_buf_index * TILE_SIZE + local_id.x * 4u + local_id.y * 16u;    

    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        let coords = xy_uint + vec2(i, 0u);
        if coords.x < config.target_width && coords.y < config.target_height {
            let fg = rgba[i];
            // Max with a small epsilon to avoid NaNs
            let a_inv = 1.0 / max(fg.a, 1e-6);
            let rgba_sep = vec4(fg.rgb * a_inv, fg.a);

            // store the premulitplied alpha color to buffer and compose it later
            fine_slice[slice_buf_index_base + i] = pack4x8unorm(fg);
        }
    } 
}

fn premul_alpha(rgba: vec4<f32>) -> vec4<f32> {
    return vec4(rgba.rgb * rgba.a, rgba.a);
}
