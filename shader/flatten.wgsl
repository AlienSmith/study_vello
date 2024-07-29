#import config
#import pathtag
#import cubic
#import transform
#import bump
#import bbox
#import drawtag

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<uniform> camera: InputTransform;

@group(0) @binding(2)
var<storage> scene: array<u32>;

@group(0) @binding(3)
var<storage> tag_monoids: array<TagMonoid>;

@group(0) @binding(4)
var<storage, read_write> intersected_bbox: array<vec4<f32>>;

@group(0) @binding(5)
var<storage, read_write> cubics: array<Cubic>;

@group(0) @binding(6)
var<storage, read_write> path_infos: array<PathInfo>;

@group(0) @binding(7)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(8)
var<storage, read_write> info: array<u32>;

@group(0) @binding(9)
var<storage> draw_monoids: array<DrawMonoid>;

var<private> pathdata_base: u32;

fn read_f32_point(ix: u32) -> vec2<f32> {
    let x = bitcast<f32>(scene[pathdata_base + ix]);
    let y = bitcast<f32>(scene[pathdata_base + ix + 1u]);
    return vec2(x, y);
}

fn read_i16_point(ix: u32) -> vec2<f32> {
    let raw = scene[pathdata_base + ix];
    let x = f32(i32(raw << 16u) >> 16u);
    let y = f32(i32(raw) >> 16u);
    return vec2(x, y);
}

fn read_transform(transform_base: u32, ix: u32) -> Transform {
    let base = transform_base + ix * 6u;
    let c0 = bitcast<f32>(scene[base]);
    let c1 = bitcast<f32>(scene[base + 1u]);
    let c2 = bitcast<f32>(scene[base + 2u]);
    let c3 = bitcast<f32>(scene[base + 3u]);
    let c4 = bitcast<f32>(scene[base + 4u]);
    let c5 = bitcast<f32>(scene[base + 5u]);
    let matrx = vec4(c0, c1, c2, c3);
    let translate = vec2(c4, c5);
    return Transform(matrx, translate);
}

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let ix = global_id.x;
    let tag_word = scene[config.pathtag_base + (ix >> 2u)];
    pathdata_base = config.pathdata_base;
    let shift = (ix & 3u) * 8u;
    var tm = reduce_tag(tag_word & ((1u << shift) - 1u));
    tm = combine_tag_monoid(tag_monoids[ix >> 2u], tm);
    var tag_byte = (tag_word >> shift) & 0xffu;
    let bbox = intersected_bbox[tm.path_ix];
    let dm = draw_monoids[tm.path_ix];
    //the path containing this pathtag is outside of screen there is no point to generate cubic for it
    if bbox.x >= bbox.z || bbox.y >= bbox.w{
        return;
    }
    let path_info = path_infos[tm.path_ix];
    let world_to_screen = Transform(camera.matrx, camera.translate);
    let local_to_world = read_transform(config.transform_base, tm.trans_ix - 1u);
    let transform = transform_mul(world_to_screen, local_to_world);
    // Decode path data
    let seg_type = tag_byte & PATH_TAG_SEG_TYPE;
    if seg_type != 0u {
        var p0: vec2<f32> = bbox.xy + path_info.stroke;
        var p1: vec2<f32> = bbox.zw - path_info.stroke;
        var p2: vec2<f32>;
        var p3: vec2<f32>;
        let len = length(p1 - p0);
        let dif = select(p1 - p0, vec2<f32>(0.01,0.01) ,len < 1e-7);
        //the bbox is too small we would just draw a line across the region
        //TODO us dif < 1.0 after switch to fix point bbox
        if len < 3.0 {
            //make it a line_to and stroke
            tag_byte = 1u;
            path_infos[tm.path_ix].flags = 1u;
            info[dm.info_offset] = bitcast<u32>(0.01);
            let p3 = p0 + dif;
            let p2 = mix(p3, p0, 1.0 / 3.0);
            let p1 = mix(p0, p3, 1.0 / 3.0);
            //all valid thread will write the same result to same location
            cubics[tm.path_ix] = Cubic(p0, p1, p2, p3, tm.path_ix, tag_byte);
            return;
        }
        if (tag_byte & PATH_TAG_F32) != 0u {
            p0 = read_f32_point(tm.pathseg_offset);
            p1 = read_f32_point(tm.pathseg_offset + 2u);
            if seg_type >= PATH_TAG_QUADTO {
                p2 = read_f32_point(tm.pathseg_offset + 4u);
                if seg_type == PATH_TAG_CUBICTO {
                    p3 = read_f32_point(tm.pathseg_offset + 6u);
                }
            }
        } else {
            p0 = read_i16_point(tm.pathseg_offset);
            p1 = read_i16_point(tm.pathseg_offset + 1u);
            if seg_type >= PATH_TAG_QUADTO {
                p2 = read_i16_point(tm.pathseg_offset + 2u);
                if seg_type == PATH_TAG_CUBICTO {
                    p3 = read_i16_point(tm.pathseg_offset + 3u);
                }
            }
        }        
        p0 = transform_apply(transform, p0);
        p1 = transform_apply(transform, p1);
        let screen_p0 = p0;
        let screen_p1 = p1;
        var bbox = vec4(min(p0, p1), max(p0, p1));
        // Degree-raise
        if seg_type == PATH_TAG_LINETO {
            p3 = p1;
            p2 = mix(p3, p0, 1.0 / 3.0);
            p1 = mix(p0, p3, 1.0 / 3.0);
        } else if seg_type >= PATH_TAG_QUADTO {
            p2 = transform_apply(transform, p2);
            bbox = vec4(min(bbox.xy, p2), max(bbox.zw, p2));
            if seg_type == PATH_TAG_CUBICTO {
                p3 = transform_apply(transform, p3);
                bbox = vec4(min(bbox.xy, p3), max(bbox.zw, p3));
            } else {
                p3 = p2;
                p2 = mix(p1, p2, 1.0 / 3.0);
                p1 = mix(p1, p0, 1.0 / 3.0);
            }
        }
        let index = atomicAdd(&bump.cubics, 1u);
        cubics[index] = Cubic(p0, p1, p2, p3, tm.path_ix, tag_byte);
    }
}
