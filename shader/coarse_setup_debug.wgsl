#import config
#import ptcl
#import bump

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(2)
var<storage, read_write> fine_index: array<u32>;

@group(0) @binding(3)
var<storage, read_write> indirect: IndirectCount;

let WG_SIZE = 256u;
let BIN_TILE_COUNT = 16u;

@compute @workgroup_size(1)
fn main(
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    //debug
    let end = config.width_in_tiles * config.height_in_tiles;
    var counter = 0u;
    var indirect_clip_counter = 0u;
    for (var i = 0u; i < end; i += 1u) {
        fine_index[i * 4u] = counter;
        let space = fine_index[i * 4u + 1u];
        counter += space;

        fine_index[i * 4u + 2u] = indirect_clip_counter;
        let indirect_clip_space = fine_index[i * 4u + 3u];
        indirect_clip_counter += indirect_clip_space;
    }

    let current_size = counter * PTCL_INCREMENT;
    atomicStore(&bump.ptcl, current_size);
    atomicStore(&bump.indirect_clips, indirect_clip_counter);
    if current_size > config.ptcl_size || indirect_clip_counter > config.indirect_clip_count{
        atomicOr(&bump.failed, STAGE_COARSE);
    }

    //consistent with wg_counts.coarse_counter
    indirect.count_x = (config.width_in_tiles + BIN_TILE_COUNT - 1u)/BIN_TILE_COUNT;
    indirect.count_y = (config.height_in_tiles + BIN_TILE_COUNT - 1u)/BIN_TILE_COUNT;
    indirect.count_z = (config.n_drawobj + WG_SIZE - 1u)/ WG_SIZE;
    //escape the coarse process to avoid potential crash
    if atomicLoad(&bump.failed) != 0u {
        indirect.count_x = 0u;
    }
}