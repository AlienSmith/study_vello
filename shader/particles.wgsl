#import config
#import clip
#import bbox
#import bump
#import segment
#import transform
#import cubic

//Local(Cubics) -> Particles -> World -> Screen

let PARTICLE_DATA_BASE = 256u;
let PARTICLE_DATA_SIZE = 6u;

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

@group(0) @binding(8)
var<storage> path_infos: array<PathInfo>;

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

//failing of binning won't have any effcts on pattern so we won't check it

fn read_particle_transform(offset: u32) -> Transform{
    let x = bitcast<f32>(particles_info[offset]);
    let y = bitcast<f32>(particles_info[offset + 1u]);
    let z = bitcast<f32>(particles_info[offset + 2u]);
    let w = bitcast<f32>(particles_info[offset + 3u]);
    let t_x = bitcast<f32>(particles_info[offset + 4u]);
    let t_y = bitcast<f32>(particles_info[offset + 5u]);
    return Transform(vec4(x,y,z,w), vec2(t_x,t_y));
}

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
    let particle_index = u32(pattern.rotation);
    let start = select(particles_info[particle_index - 1u], 0u, particle_index == 0u);
    let end = particles_info[particle_index];
    let size = end - start;

    let cubic_ix = atomicAdd(&bump.cubics, size - 1u);
    if cubic_ix + size > config.cubic_size{
        atomicOr(&bump.failed, STAGE_PATTERN);
        return;
    }

    let path_info = path_infos[oup.path_ix];
    let particles_to_world = Transform(vec4(path_info.local_to_world_xy, path_info.local_to_world_zw), path_info.local_to_world_t);
    let world_to_screen = Transform(camera.matrx, camera.translate);
    let particles_to_screen = transform_mul(world_to_screen, particles_to_world);

    for (var ix = start; ix < end; ix++){
        let offset = PARTICLE_DATA_BASE + ix * PARTICLE_DATA_SIZE;
        let local_to_particles = read_particle_transform(offset);
        //let pos_x = bitcast<f32>(particles_info[offset + 4u]);
        //let pos_y = bitcast<f32>(particles_info[offset + 5u]);
        let transform = transform_mul(particles_to_screen, local_to_particles);
        //let delta = temp.translate;
        let store_index = select(cubic_ix + ix - start, index, ix == end - 1u);
        let op0 = transform_apply(transform, oup.p0);
        let op1 = transform_apply(transform, oup.p1);
        let op2 = transform_apply(transform, oup.p2);
        let op3 = transform_apply(transform, oup.p3);
        let instance = Cubic(op0, op1, op2, op3, oup.path_ix, oup.tag_byte);
        cubic[store_index] = instance;
    }
}