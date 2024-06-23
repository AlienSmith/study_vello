//fine composer compose the result of slice buf to output

#import config
#import bump
#import ptcl
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var output: texture_storage_2d<rgba8unorm, write>;

@group(0) @binding(2)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(3)
var<storage> fine_info: array<u32>;

let PIXELS_PER_THREAD = 4u;

@compute @workgroup_size(4, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    if atomicLoad(&bump.failed) != 0u {
        return;
    }
    
    let fine_slice_base = config.width_in_tiles * config.height_in_tiles * 4u;
    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2(f32(global_id.x * PIXELS_PER_THREAD), f32(global_id.y));
    let xy_uint = vec2<u32>(xy);
    var rgba: array<vec4<f32>, PIXELS_PER_THREAD>;
    var current_layer_index = 0u;

    let start_index = select(0u, fine_info[tile_ix - 1u], tile_ix > 0u);
    let slice_count = fine_info[tile_ix] - start_index;
    for(var j = 0u; j < PIXELS_PER_THREAD; j += 1u){
        rgba[j] = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    //compose
    for(var i = 0u; i < slice_count; i += 1u){
        let slice_buf_index_base = fine_slice_base + (start_index + i) * TILE_SIZE + local_id.x * 4u + local_id.y * 16u;
        for(var j = 0u; j < PIXELS_PER_THREAD; j += 1u){
            let coords = xy_uint + vec2(j, 0u);
            if coords.x < config.target_width && coords.y < config.target_height {
                let current = unpack4x8unorm(fine_info[slice_buf_index_base + j]);
                rgba[j] = rgba[j] * (1.0 - current.w) + current;
            }
        }
    }
    
    //write to texture
    for(var i = 0u; i < PIXELS_PER_THREAD; i += 1u){
        let coords = xy_uint + vec2(i, 0u);
        if coords.x < config.target_width && coords.y < config.target_height {
            let fg = rgba[i];
            let a_inv = 1.0 / max(fg.a, 1e-6);
            let rgba_sep = vec4(fg.rgb * a_inv, fg.a);
            textureStore(output, vec2<i32>(coords), rgba_sep);
        }
    }        
}