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
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> pattern_inp: array<PatternInp>;

@group(0) @binding(3)
var<storage> clip_bbox_buf: array<vec4<f32>>;

@group(0) @binding(3)
var<storage, read_write> path_bboxes: array<PathBbox>;

@group(0) @binding(4)
var<storage, read_write> cubics: array<Cubic>;

let WG_SIZE = 256u;

var<workgroup> sh_cubic_counts: array<u32, WG_SIZE>;

fn read_pattern(pattern_base:u32, ix:u32) -> Pattern {
    let base = transform_base + ix * 5u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base + 1u]);
    let c2 = bitcast<f32>(scene[base + 2u]);
    let c3 = bitcast<f32>(scene[base + 3u]);
    let c4 = bitcast<f32>(scene[base + 4u]);
    let start = vec2(c0, c1);
    let box_scale = vec2(c2, c3);
    return Pattern(start, box_scale, rotation);
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
    if ix < config.n_patterns{
        let pattern = pattern_inp[ix];
        let clip_bbox = clip_bbox_buf[pattern.clip_ix];
        let repeat_des = read_pattern(ix);
        let SX = (1.0 / pattern.box_scale.x);
        let SY = (1.0 / pattern.box_scale.y);
        let min_x = round_down(pattern.start.x * -1.0 * SX);
        let min_y = round_down(pattern.start.y * -1.0 * SY);
        let max_x = round_up((clip_bbox.z - clip_bbox.x - pattern.start.x)* SX);
        let max_y = round_up((clip_bbox.w - clip_bbox.y - pattern.start.y)* SX);
        let previous_cubic_count = select(0u, path_bboxes[pattern.begin_path_ix - 1u], pattern.begin_path_ix > 1u);
        let finish_cubic_count = select(0u, path_bboxes[pattern.end_path_ix - 1u], pattern.end_path_ix > 1u);
        let cubic_count = (finish_cubic_count - previous_cubic_count -1) * (max_x - min_x) * (max_y - min_y);
        sh_cubic_counts[local_id.x] = cubic_count;
        for (var i = 0u; i < firstTrailingBit(WG_SIZE); i += 1u) {
            workgroupBarrier();
            if local_id.x >= (1u << i) {
                cubic_count += sh_cubic_counts[local_id.x - (1u << i)];
            }
            workgroupBarrier();
        }
        let cubic_offset = select(0u, sh_cubic_counts[local_id.x - 1u], local_id.x > 1u);
        var one_path_cubic_count = 0u;
        for (var i = pattern.begin_path_ix; i < pattern.end_path_ix; i += 1u) {
            //reset path bounding box to clip box
            let out = &path_bboxes[i];
            (*out).x0 = clip_bbox.x;
            (*out).y0 = clip_bbox.y;
            (*out).x1 = clip_bbox.z;
            (*out).y1 = clip_bbox.w;
        
        }
    }
}
