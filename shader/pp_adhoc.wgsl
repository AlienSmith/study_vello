#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> pp_input: array<u32>;

@group(0) @binding(2)
var<storage> pp_flag: array<u32>;

@group(0) @binding(3)
var<storage,read_write> pp_input1: array<u32>;

// @group(0) @binding(3)
// var output: texture_storage_2d<rgba8unorm, write>;
let ELIPION = 1e-2;
let PIXEL_PER_COLUM = 3u;
let PIXELS_PER_ROW = 3u;
let N_PIXELS = 9u;
var<private> samples_array: array<vec4<f32>,N_PIXELS>;
var<private> seam_array: array<u32,N_PIXELS>;
var<private> result: vec4<f32>;
var<private> result_brightness: f32;
fn brightness(color:vec4<f32>) -> f32{
   return color.a * ((0.21 * color.r) + (0.72 * color.g) + (0.07 * color.b));      
}

fn unpack_color_with_flag( packed_color:u32, flag: ptr<function,u32>) -> vec4<f32>{
    
    let r = f32((packed_color >> 24u) & 0xffu) / 255.0;
    let g = f32((packed_color >> 16u) & 0xffu) / 255.0;
    let b = f32((packed_color >> 8u) & 0xffu) / 255.0;
    let a = f32((packed_color >> 1u) & 0xffu) / 127.0;
    let f = packed_color & 0x1u;
    if a != 0.0 {
        *flag = f;
    }
    return vec4<f32>(r,g,b,a);
}

// fn seam_fix(index1:u32, index2:u32){
//     let point1 = samples_array[index1];
//     let point2 = samples_array[index2];
//     let seam1 = seam_array[index1];
//     let seam2 = seam_array[index2];
//     if seam1 == 1u && seam2 == 1u {
//         return;
//     }
//     let b11 = dot(point1, point1);
//     let b12 = dot(point1, point2);
//     if b11 != b12 && (seam1 + seam2 != 0u){
//         return;
//     }

//     result = (point1 + point2) * 0.5;
// }

fn seam_fix(index1:u32, index2:u32){
    let point1 = samples_array[index1];
    let point2 = samples_array[index2];
    let seam1 = seam_array[index1];
    let seam2 = seam_array[index2];
    if seam1 == 1u && seam2 == 1u {
        return;
    }
    let b11 = dot(point1, point1);
    let b12 = dot(point1, point2);
    let b22 = dot(point2, point2);
    let error = (b11 + b12 + b22) * ELIPION;
    if (abs(b11 - b12) > error || abs(b12 - b22) > error) && (seam1 + seam2 != 0u){
        return;
    }

    let temp = (point1 + point2) * 0.5;
    let original = samples_array[4u];
    if length(temp.xyz - original.xyz) > length(result.xyz - original.xyz) && length(result - original) != 0.0{
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
                    var temp = 0u;
                    samples_array[i * 3u + j] = unpack4x8unorm(pp_input[point.x + point.y * config.target_width]);
                    seam_array[i * 3u + j] = pp_flag[point.x + point.y * config.target_width];
                }    
            }
            result = samples_array[4u];
            //result_brightness = brightness(result);
            if seam_array[4] != 0u{
                for ( var i = 0u; i < 4u; i+=1u){
                    seam_fix(i, (N_PIXELS - i - 1u));
                }
                //seam_fix(2u, 6u);
            }
        }else{
            result = unpack4x8unorm(pp_input[coords.x + coords.y * config.target_width]);
        }
        pp_input1[coords.x + coords.y * config.target_width] = pack4x8unorm(result);
        //textureStore(output, vec2<i32>(coords), result);
        // var temp = pp_flag[coords.x + coords.y * config.target_width];
        // if temp == 0u{
        //     textureStore(output, vec2<i32>(coords), vec4<f32>(0.0,0.0,0.0,0.0));
        // }else{
        //     textureStore(output, vec2<i32>(coords), vec4<f32>(1.0,1.0,1.0,1.0));
        // }
    }
}