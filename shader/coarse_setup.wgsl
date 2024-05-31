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
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(2)
var<storage> counter: array<i32>;

@group(0) @binding(3)
var<storage, read_write> coarse_index: array<u32>;

@group(0) @binding(4)
var<storage, read_write> fine_index: array<u32>;

// Much of this code assumes WG_SIZE == N_TILE. If these diverge, then
// a fair amount of fixup is needed.
let WG_SIZE = 256u;
let N_CLIPS = 4u;
// helper functions for writing ptcl
var<private> clip_stack: array<u32,N_CLIPS>;
var<private> clip_stack_end: i32;
// Make sure there is space for a command of given size, plus a jump if needed

@compute @workgroup_size(256)
fn main(
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
    @builtin(global_invocation_id) global_id: vec3<u32>,
) {
    let bin_tile_x = N_TILE_X * wg_id.x;
    let bin_tile_y = N_TILE_Y * wg_id.y;

    let tile_x = local_id.x % N_TILE_X;
    let tile_y = local_id.x / N_TILE_X;
    if bin_tile_x + tile_x < config.width_in_tiles && bin_tile_y + tile_y < config.height_in_tiles {
        let n_partitions = (config.n_drawobj + N_TILE - 1u) / N_TILE;
        let bin_x = config.width_in_tiles + N_TILE_X - 1u / N_TILE_X;
        let bin_y = config.height_in_tiles + N_TILE_Y - 1u/ N_TILE_Y;
        let this_tile_ix = (bin_tile_y + tile_y) * config.width_in_tiles + bin_tile_x + tile_x;
        let stride = config.width_in_tiles * config.height_in_tiles;
        var ptcl_slice_offsets = 0u;
        var current_clip_index = 1u;
        clip_stack_end = 0;
        var layer_counter = 0u;
        for (var i = 0u; i < n_partitions; i += 1u) {
            let index = this_tile_ix + i * stride;
            coarse_index[index * 3u] = (ptcl_slice_offsets & 0xfffu) | ((layer_counter & 0xfu) << 12u) | (current_clip_index << 16u);
            coarse_index[index * 3u + 1u] = (clip_stack[0] & 0xffffu) | (clip_stack[1] << 16u);
            coarse_index[index * 3u + 2u] = (clip_stack[2] & 0xffffu) | (clip_stack[3] << 16u);
            ptcl_slice_offsets += u32(counter[index * 2u] >> 4u);
            layer_counter += u32(counter[index * 2u] & 0xf);
            let clips = counter[index * 2u + 1u];
            let delta = abs(clips);
            for(var j = 0; j < delta; j += 1){
                if clips > 0{
                    clip_stack[clip_stack_end] = current_clip_index;
                    current_clip_index += 1u;
                    clip_stack_end += 1;
                }else{
                    clip_stack_end -= 1;
                    clip_stack[clip_stack_end] = 0u;
                }
            }
        }
        fine_index[this_tile_ix * 4u + 1u] = ptcl_slice_offsets;
        fine_index[this_tile_ix * 4u + 3u] = current_clip_index;

        //debug with debug shader
        let size = ptcl_slice_offsets * PTCL_INCREMENT;
        let base_size = atomicAdd(&bump.ptcl, size);
        let base_offset = base_size / PTCL_INCREMENT;
        fine_index[this_tile_ix * 4u] = base_offset;

        let indirect_clip_offset = atomicAdd(&bump.indirect_clips, current_clip_index);
        fine_index[this_tile_ix * 4u + 2u] = indirect_clip_offset;
        if base_size + size > config.ptcl_size || indirect_clip_offset + current_clip_index > config.indirect_clip_count{
            atomicOr(&bump.failed, STAGE_COARSE);
        }
    }
}
