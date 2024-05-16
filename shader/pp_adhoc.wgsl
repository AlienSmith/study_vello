#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> pp_input: array<u32>;

@group(0) @binding(2)
var output: texture_storage_2d<rgba8unorm, write>;
let ELIPION = 0.03;
let PIXEL_PER_COLUM = 3u;
let PIXELS_PER_ROW = 3u;
let N_PIXELS = 9u;
var<private> samples_array: array<vec4<f32>,N_PIXELS>;
var<private> result: vec4<f32>;

fn check(index1:u32, index2:u32){
    let point1 = samples_array[index1];
    let point2 = samples_array[index2];
    if result.a > point1.a || result.a > point2.a{
        return;
    }
    let b11 = dot(point1.xyz, point1.xyz);
    let b12 = dot(point1.xyz, point2.xyz);
    let b22 = dot(point2.xyz, point2.xyz);
    let error = (b11 + b12 + b22) * ELIPION;
    if abs(b11 - b12) > error || abs(b12 - b22) > error{
        return;
    }
    let b33 = dot(result.xyz, result.xyz);
    let b13 = dot(point1.xyz, result.xyz);
    let b23 = dot(point2.xyz, result.xyz);
    if abs(b33 - b13) > error || abs(b23 - b22) > error{
        return;
    }
    result = (point1 + point2) * 0.5;
}

@compute @workgroup_size(16, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2(f32(global_id.x), f32(global_id.y));
    let coords = vec2<u32>(xy);

    if coords.x < config.target_width && coords.y < config.target_height {
        if coords.x > 0u && coords.x < (config.target_width - 1u) && coords.y > 0u && coords.y < (config.target_height - 1u){
            let tl = coords - vec2<u32>(1u,1u);
            for (var i = 0u; i < 3u; i += 1u) {
                for (var j = 0u; j < 3u; j += 1u) {
                    let point = tl + vec2<u32>(i,j);
                    samples_array[i * 3u + j] = unpack4x8unorm(pp_input[point.x + point.y * config.target_width]);
                }    
            }
            result = samples_array[4u];
            for ( var i = 0u; i < 4u; i+=1u){
                check(i, (N_PIXELS - i - 1u));
            }
        }else{
            result = unpack4x8unorm(pp_input[coords.x + coords.y * config.target_width]);
        }
        textureStore(output, vec2<i32>(coords), result);
    }
}