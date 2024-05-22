#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> pp_input1: array<u32>;

@group(0) @binding(2)
var output: texture_storage_2d<rgba8unorm, write>;

@compute @workgroup_size(16, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2(f32(global_id.x), f32(global_id.y));
    let coords = vec2<u32>(xy);

    if coords.x < config.target_width - 1u && coords.y < config.target_height - 1u {

        let result1 = unpack4x8unorm(pp_input1[coords.x + coords.y * config.target_width]);
        let result2 = unpack4x8unorm(pp_input1[coords.x + 1u + (coords.y + 1u) * config.target_width]);
        let result3 = unpack4x8unorm(pp_input1[coords.x + 1u + coords.y * config.target_width]);
        let result4 = unpack4x8unorm(pp_input1[coords.x + (coords.y + 1u) * config.target_width]);
        let result = 0.25 * (result1 + result2 + result3 + result4);
        textureStore(output, vec2<i32>(coords), result);
    }
}