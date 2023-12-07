// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Path segment decoding for the full case.

// In the simple case, path segments are decoded as part of the coarse
// path rendering stage. In the full case, they are separated, as the
// decoding process also generates bounding boxes, and those in turn are
// used for tile allocation and clipping; actual coarse path rasterization
// can't proceed until those are complete.

// There's some duplication of the decoding code but we won't worry about
// that just now. Perhaps it could be factored more nicely later.

#import config
#import pathtag
#import cubic
#import clip
#import transform
#import bbox
#import bump

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> pattern_inp: array<PatternInp>;

@group(0) @binding(3)
var<storage> clip_bbox_buf: array<vec4<f32>>;

@group(0) @binding(4)
var<storage, read_write> path_bboxes: array<PathBbox>;

@group(0) @binding(5)
var<storage, read_write> cubics: array<Cubic>;

@group(0) @binding(6)
var<storage, read_write> bump: BumpAllocators;

let WG_SIZE = 256u;
var<workgroup> sh_cubic_counts: array<u32, WG_SIZE>;

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

fn round_down(x: f32) -> i32 {
    return i32(floor(x));
}

fn round_up(x: f32) -> i32 {
    return i32(ceil(x));
}

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let ix = global_id.x;
    //if ix < 0u {
    if ix < (config.n_patterns >> 1u){
        let pattern = pattern_inp[ix];
        let clip_bbox = clip_bbox_buf[pattern.clip_ix];
        let pattern_des = read_pattern(config.pattern_base, ix);
        let SX = (1.0 / pattern_des.box_scale.x);
        let SY = (1.0 / pattern_des.box_scale.y);
        let min_x = round_down(pattern_des.start.x * -1.0 * SX);
        let min_y = round_down(pattern_des.start.y * -1.0 * SY);
        let max_x = round_up((clip_bbox.z - clip_bbox.x - pattern_des.start.x)* SX);
        let max_y = round_up((clip_bbox.w - clip_bbox.y - pattern_des.start.y)* SX);

        let pox_x = clip_bbox.x + pattern_des.start.x;
        let pox_y = clip_bbox.y + pattern_des.start.y;
        let delta_x = pattern_des.box_scale.x;
        let delta_y = pattern_des.box_scale.y;

        let previous_cubic_count = select(0u, path_bboxes[pattern.begin_path_ix - 1u].last_tag_ix, pattern.begin_path_ix > 0u);
        let finish_cubic_count = select(0u, path_bboxes[pattern.end_path_ix - 1u].last_tag_ix, pattern.end_path_ix > 0u);
        var cubic_count = (finish_cubic_count - previous_cubic_count) * u32(max_x - min_x) * u32(max_y - min_y);
        sh_cubic_counts[local_id.x] = cubic_count;
        for (var i = 0u; i < firstTrailingBit(WG_SIZE); i += 1u) {
            workgroupBarrier();
            if local_id.x >= (1u << i) {
                cubic_count += sh_cubic_counts[local_id.x - (1u << i)];
            }
            workgroupBarrier();
        }
        if (local_id.x == 0u){
            let ix = min((config.n_patterns >> 1u) - 1u, WG_SIZE - 1u);
            bump.pattern_cubic = sh_cubic_counts[ix];
        }
        let cubic_offset = 128u + select(0u, sh_cubic_counts[local_id.x - 1u], local_id.x > 1u);
        var local_count = 0u;
        for (var i = pattern.begin_path_ix; i < pattern.end_path_ix; i += 1u) {
            let out = &path_bboxes[i];
            (*out).x0 = i32(clip_bbox.x);
            (*out).y0 = i32(clip_bbox.y);
            (*out).x1 = i32(clip_bbox.z);
            (*out).y1 = i32(clip_bbox.w);
        }
        var local_offset = 0u;
        for(var ix = min_x; ix < max_x; ix += 1){
            for(var iy = min_y; iy < max_y; iy += 1){
                let pivot_x = pox_x + f32(ix) * delta_x;
                let pivot_y = pox_y +  f32(iy) * delta_y;
                let pivot = vec2(pivot_x, pivot_y);
                for (var i = pattern.begin_path_ix; i < pattern.end_path_ix; i += 1u) {
                    let cubic_start = select(0u, path_bboxes[i - 1u].last_tag_ix, i > 0u);
                    let cubic_end = path_bboxes[i].last_tag_ix;
                    for(var cubic_ix = cubic_start; cubic_ix < cubic_end; cubic_ix += 1u){
                        var instance = cubics[cubic_ix];
                        instance.p0 += pivot;
                        instance.p1 += pivot;
                        instance.p2 += pivot;
                        instance.p3 += pivot;
                        if(ix == max_x - 1 && iy == max_y - 1){
                            cubics[cubic_ix] = instance;
                        }else{
                            cubics[cubic_offset + local_offset] = instance;
                            local_offset += 1u;
                        }
                    }
                }
            }
        }
    }
}
