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
var<storage> fine_index: array<u32>;

@group(0) @binding(3)
var<storage> fine_slice: array<u32>;

@group(0) @binding(4)
var<storage> bump: BumpAllocators;

@group(0) @binding(5)
var<storage> layer_info: array<f32>;

var<private> layer_blend_index: array<u32, MAX_LAYER_COUNT>;

var<private> layer_blend_alpha: array<f32, MAX_LAYER_COUNT>;

let PIXELS_PER_THREAD = 4u;

fn read_layer_blend_info(tile_ix: u32){
   let index = tile_ix * LAYER_INFOR_SIZE;
   for(var j = 0u; j < MAX_LAYER_COUNT; j += 1u){
     layer_blend_index[j] = u32(layer_info[index + j * 2u]) - 1u;
     layer_blend_alpha[j] = bitcast<f32>(layer_info[index + j * 2u + 1u]);
   }
}

@compute @workgroup_size(4, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    if atomicLoad(&bump.failed) != 0u {
        return;
    }

    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2(f32(global_id.x * PIXELS_PER_THREAD), f32(global_id.y));
    let xy_uint = vec2<u32>(xy);
    var rgba_bg: array<vec4<f32>, PIXELS_PER_THREAD>;
    var rgba: array<vec4<f32>, PIXELS_PER_THREAD>;
    var current_layer_index = 0u;
    read_layer_blend_info(tile_ix);

    let start_index = select(0u, fine_index[tile_ix - 1u], tile_ix > 0u);
    let slice_count = min(2u,fine_index[tile_ix] - start_index);
    for(var j = 0u; j < PIXELS_PER_THREAD; j += 1u){
        rgba[j] = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        rgba_bg[j] = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    //compose
    for(var i = 0u; i < slice_count; i += 1u){
        let slice_buf_index_base = (start_index + i) * TILE_SIZE + local_id.x * 4u + local_id.y * 16u;
        let need_blend = i == layer_blend_index[current_layer_index];
        for(var j = 0u; j < PIXELS_PER_THREAD; j += 1u){
            let coords = xy_uint + vec2(j, 0u);
            if coords.x < config.target_width && coords.y < config.target_height {
                let current = unpack4x8unorm(fine_slice[slice_buf_index_base + j]);
                rgba[j] = rgba[j] * (1.0 - current.w) + current;
                // if need_blend {
                //     rgba[j] *= layer_blend_alpha[current_layer_index];
                //     rgba_bg[j] = rgba_bg[j] * (1.0 - rgba[j].w) + rgba[j];
                //     rgba[j] = vec4<f32>(0.0, 0.0, 0.0, 0.0);
                // }
            }
        }    
        current_layer_index += select(0u,1u, need_blend);
    }
    
    //write to texture
    for(var i = 0u; i < PIXELS_PER_THREAD; i += 1u){
        let coords = xy_uint + vec2(i, 0u);
        if coords.x < config.target_width && coords.y < config.target_height {
            //let fg = rgba_bg[i];
            let fg = rgba[i];
            let a_inv = 1.0 / max(fg.a, 1e-6);
            let rgba_sep = vec4(fg.rgb * a_inv, fg.a);
            textureStore(output, vec2<i32>(coords), rgba_sep);
        }
    }        
}