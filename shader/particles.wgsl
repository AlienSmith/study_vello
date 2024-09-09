#import config
#import clip
#import bbox
#import bump
#import segment
#import transform
#import cubic

let PARTICLE_DATA_BASE = 256u;
let PARTICLE_DATA_SIZE = 2u;

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<uniform> camera: InputTransform;

@group(0) @binding(2)
var<storage> scene: array<u32>;

@group(0) @binding(3)
var<storage> clip_bbox_buf: array<vec4<f32>>;

@group(0) @binding(4)
var<storage> path_to_pattern: array<PatternInp>;

@group(0) @binding(5)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(6)
var<storage, read_write> cubic: array<Cubic>;

@group(0) @binding(7)
var<storage> particles_info: array<u32>;

var<private> is_in_screen_space: bool;
var<private> bbox: vec4<f32>;
var<private> screen_to_world: Transform;
var<private> world_to_screen: Transform;
var<private> screen_to_pattern: Transform;
var<private> pattern_to_screen: Transform;

fn read_pattern(pattern_base:u32, ix:u32) -> Pattern {
    let base = pattern_base + ix * 6u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base + 1u]);
    let c2 = bitcast<f32>(scene[base + 2u]);
    let c3 = bitcast<f32>(scene[base + 3u]);
    let c4 = bitcast<f32>(scene[base + 4u]);
    let c5 = bitcast<u32>(scene[base + 5u]);
    let start = vec2(c0, c1);
    let box_scale = vec2(c2, c3);
    return Pattern(start, box_scale, c4, c5);
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
    var pattern = offset;
    pattern += transform_apply(screen_to_world, p);
    pattern = transform_apply(pattern_to_screen, pattern);
    return pattern;
}
//failing of binning won't have any effcts on pattern so we won't check it

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    //we are not interested in pathes which got optimized to one storke line
    let index = global_id.x + config.n_path;
    if(index >= bump.intermidiate.x){
        return;
    }
    let oup = cubic[index];
    let info = path_to_pattern[oup.path_ix];

    if info.pattern_ix == 0u {
        return;
    }
    let pattern = read_pattern(config.pattern_base, info.pattern_ix - 1u);

    if pattern.is_screen_space < PARTICLES_IN_LOCAL_SPACE {
        return;
    }
    let particle_index = 0u;
    let start = select(particles_info[particle_index - 1u], 0u, particle_index == 0u);
    let end = particles_info[particle_index];
    let size = end - start;

    let cubic_ix = atomicAdd(&bump.cubics, size - 1u);
    if cubic_ix + size > config.cubic_size{
        atomicOr(&bump.failed, STAGE_PATTERN);
        return;
    }

    //for non screen space pattern the matrix stores in scene buffer is not the local to world matrix
    //it is more like a child to parent matrix and the parent space need to be repeated and transformed to have pattern in world space
    world_to_screen = Transform(camera.matrx, camera.translate);
    screen_to_world = transform_inverse(world_to_screen);

    let p0 = transform_apply(screen_to_world, oup.p0);
    let p1 = transform_apply(screen_to_world, oup.p1);
    let p2 = transform_apply(screen_to_world, oup.p2);
    let p3 = transform_apply(screen_to_world, oup.p3);


    for (var ix = start; ix < end; ix++){
        let offset = PARTICLE_DATA_BASE + ix * PARTICLE_DATA_SIZE;
        let pos_x = bitcast<f32>(particles_info[offset]);
        let pos_y = bitcast<f32>(particles_info[offset + 1u]);
        let delta = vec2(pos_x, pos_y);
        let store_index = select(cubic_ix + ix - start, index, ix == end - 1u);
        let op0 = transform_apply(world_to_screen, p0 + delta);
        let op1 = transform_apply(world_to_screen, p1 + delta);
        let op2 = transform_apply(world_to_screen, p2 + delta);
        let op3 = transform_apply(world_to_screen, p3 + delta);
        let instance = Cubic(op0, op1, op2, op3, oup.path_ix, oup.tag_byte);
        cubic[store_index] = instance;
    }
}