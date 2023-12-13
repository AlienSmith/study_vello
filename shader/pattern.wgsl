#import config
#import clip
#import bbox
#import bump
#import segment
#import transform

struct InputTransform {
   m1:f32,
   m2:f32,
   m3:f32,
   m4:f32,
   t1:f32,
   t2:f32,
}

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<uniform> camera: InputTransform;

@group(0) @binding(2)
var<storage> scene: array<u32>;

@group(0) @binding(3)
var<storage> clip_bbox_buf: array<vec4<f32>>;

@group(0) @binding(4)
var<storage> path_to_pattern: array<PathtoDraw>;

@group(0) @binding(5)
var<storage, read_write> path_bbox: array<PathBbox>;

@group(0) @binding(6)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(7)
var<storage, read_write> lines: array<LineSoup>;


var<private> bbox: vec4<f32>;
var<private> pattern_to_world: Transform;
var<private> world_to_pattern: Transform;
var<private> screen_to_world: Transform;
var<private> world_to_screen: Transform;
var<private> screen_to_pattern: Transform;
var<private> pattern_to_screen: Transform;

fn read_pattern(pattern_base:u32, ix:u32) -> Pattern {
    let base = pattern_base + ix * 5u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base + 1u]);
    let c2 = bitcast<f32>(scene[base + 2u]);
    let c3 = bitcast<f32>(scene[base + 3u]);
    let c4 = bitcast<f32>(scene[base + 4u]);
    let start = vec2(c0, c1);
    let box_scale = vec2(c2, c3);
    return Pattern(start, box_scale, c4);
}

fn compare_bbox(point: vec2<f32>){
    let p = transform_apply(screen_to_pattern, point);
    bbox.x = min(p.x, bbox.x);
    bbox.y = min(p.y, bbox.y);
    bbox.z = max(p.x, bbox.z);
    bbox.w = max(p.y, bbox.w);
}

fn round_down(x: f32) -> i32 {
    return i32(floor(x));
}

fn round_up(x: f32) -> i32 {
    return i32(ceil(x));
}

fn apply_offset(p: vec2<f32>, offset: vec2<f32>) -> vec2<f32>{
    var pattern = transform_apply(screen_to_world, p) + offset;
    pattern = transform_apply(pattern_to_screen, pattern);
    return pattern;
}

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let count = atomicLoad(&bump.lines_before);
    let index = global_id.x;
    if(index >= count){
        return;
    }
    let soup = lines[index];
    let info = path_to_pattern[soup.path_ix];

    if info.pattern_ix == 0u {
        return;
    }
    world_to_screen =Transform(vec4<f32>(camera.m1,camera.m2,camera.m3,camera.m4), vec2<f32>(camera.t1,camera.t2));
    screen_to_world = transform_inverse(world_to_screen);

    bbox = vec4(1e9, 1e9, -1e9, -1e9);
    let pattern = read_pattern(config.pattern_base, info.pattern_ix - 1u);
    let clip_bbox = clip_bbox_buf[info.clip_ix - 1u];

    //We don't care which thread does the write it will be the same
    let out = &path_bbox[soup.path_ix];
    (*out).x0 = i32(clip_bbox.x);
    (*out).y0 = i32(clip_bbox.y);
    (*out).x1 = i32(clip_bbox.z);
    (*out).y1 = i32(clip_bbox.w);
    let center = vec2<f32>(0.5 * ( clip_bbox.x + clip_bbox.z), 0.5 * (clip_bbox.y + clip_bbox.w));
    let world_center = transform_apply(screen_to_world, center);

    let sin_theta = sin(pattern.rotation);
    let cos_theta = cos(pattern.rotation);
        
    let pox_x = world_center.x + pattern.start.x;
    let pox_y = world_center.y + pattern.start.y;
    let delta_x = pattern.box_scale.x;
    let delta_y = pattern.box_scale.y;

    pattern_to_world = Transform(vec4(cos_theta, sin_theta, -1.0 * sin_theta, cos_theta), vec2(pox_x, pox_y));
    let rotate = vec4(cos_theta, -1.0 * sin_theta, sin_theta, cos_theta);
    let translated = rotate.xy * -1.0 * pox_x + rotate.zw * -1.0 * pox_y;
    world_to_pattern = Transform(rotate, translated);

    pattern_to_screen = transform_mul(world_to_screen, pattern_to_world);
    screen_to_pattern = transform_mul(world_to_pattern,screen_to_world);

    compare_bbox(clip_bbox.xy);
    compare_bbox(clip_bbox.xw);
    compare_bbox(clip_bbox.zy);
    compare_bbox(clip_bbox.zw);

    let SX = (1.0 / pattern.box_scale.x);
    let SY = (1.0 / pattern.box_scale.y);
    let min_x = round_down(bbox.x * SX);
    let min_y = round_down(bbox.y * SY);
    let max_x = round_up(bbox.z * SX);
    let max_y = round_up(bbox.w * SX);

    var line_count =  u32(max_x - min_x) * u32(max_y - min_y) - 1u;
    let line_ix = atomicAdd(&bump.lines, line_count);

    var local_offset = 0u;
    for(var ix = min_x; ix < max_x; ix += 1){
        for(var iy = min_y; iy < max_y; iy += 1){
            let pivot_x = f32(ix) * delta_x;
            let pivot_y = f32(iy) * delta_y;
            let pivot = vec2(pivot_x, pivot_y);
            let p0 = apply_offset(soup.p0, pivot);
            let p1 = apply_offset(soup.p1, pivot);
            let instance = LineSoup(soup.path_ix, p0, p1);
            if(ix == min_x && iy == min_y){
                lines[index] = instance;
            }
            else{
                lines[line_ix + local_offset] = instance;
                local_offset += 1u;
            }
        }
    }
}