// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Fine rasterizer. This can run in simple (just path rendering) and full
// modes, controllable by #define.

// This is a cut'n'paste w/ backdrop.
struct Tile {
    backdrop: i32,
    segments: u32,
}

struct ReverseItem {
    area: array<f32, PIXELS_PER_THREAD>,
    rgba: array<vec4<f32>, PIXELS_PER_THREAD>,
    clip_depth: u32,        // vello has only 4 slots for clip depth, but the clip_depth here we just need to know the increase or decrease trend
    clip_end_cmd_ix: u32,
    cmd_tag: u32,           // we only need CMD_COLOR CMD_LIN_GRAD CMD_RAD_GRAD and CMD_IMAGE
    status: u32,            // save the cmd process status
                            // 0b-00000 - nothing happend
                            // 0b-00001 - area filled
                            // 0b-00010 - rgba filled
                            // 0b-00100 - clip end
                            // 0b-01000 - clip begin
}

const CMD_LENGTH = 16u;

#import segment
#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> tiles: array<Tile>;

@group(0) @binding(2)
var<storage> segments: array<Segment>;

#import blend
#import ptcl

let GRADIENT_WIDTH = 512;

@group(0) @binding(3)
var output: texture_storage_2d<rgba8unorm, write>;

@group(0) @binding(4)
var<storage> ptcl: array<u32>;

@group(0) @binding(5)
var gradients: texture_2d<f32>;

@group(0) @binding(6)
var<storage> info: array<u32>;

@group(0) @binding(7)
var image_atlas: texture_2d<f32>;

fn read_fill(cmd_ix: u32) -> CmdFill {
    let tile = ptcl[cmd_ix + 1u];
    let backdrop = i32(ptcl[cmd_ix + 2u]);
    return CmdFill(tile, backdrop);
}

fn read_stroke(cmd_ix: u32) -> CmdStroke {
    let tile = ptcl[cmd_ix + 1u];
    let half_width = bitcast<f32>(ptcl[cmd_ix + 2u]);
    return CmdStroke(tile, half_width);
}

fn read_color(cmd_ix: u32) -> CmdColor {
    let rgba_color = ptcl[cmd_ix + 1u];
    return CmdColor(rgba_color);
}

fn read_lin_grad(cmd_ix: u32) -> CmdLinGrad {
    let index = ptcl[cmd_ix + 1u];
    let info_offset = ptcl[cmd_ix + 2u];
    let line_x = bitcast<f32>(info[info_offset]);
    let line_y = bitcast<f32>(info[info_offset + 1u]);
    let line_c = bitcast<f32>(info[info_offset + 2u]);
    return CmdLinGrad(index, line_x, line_y, line_c);
}

fn read_rad_grad(cmd_ix: u32) -> CmdRadGrad {
    let index = ptcl[cmd_ix + 1u];
    let info_offset = ptcl[cmd_ix + 2u];
    let m0 = bitcast<f32>(info[info_offset]);
    let m1 = bitcast<f32>(info[info_offset + 1u]);
    let m2 = bitcast<f32>(info[info_offset + 2u]);
    let m3 = bitcast<f32>(info[info_offset + 3u]);
    let matrx = vec4(m0, m1, m2, m3);
    let xlat = vec2(bitcast<f32>(info[info_offset + 4u]), bitcast<f32>(info[info_offset + 5u]));
    let c1 = vec2(bitcast<f32>(info[info_offset + 6u]), bitcast<f32>(info[info_offset + 7u]));
    let ra = bitcast<f32>(info[info_offset + 8u]);
    let roff = bitcast<f32>(info[info_offset + 9u]);
    return CmdRadGrad(index, matrx, xlat, c1, ra, roff);
}

fn read_image(cmd_ix: u32) -> CmdImage {
    let info_offset = ptcl[cmd_ix + 1u];
    let m0 = bitcast<f32>(info[info_offset]);
    let m1 = bitcast<f32>(info[info_offset + 1u]);
    let m2 = bitcast<f32>(info[info_offset + 2u]);
    let m3 = bitcast<f32>(info[info_offset + 3u]);
    let matrx = vec4(m0, m1, m2, m3);
    let xlat = vec2(bitcast<f32>(info[info_offset + 4u]), bitcast<f32>(info[info_offset + 5u]));
    let xy = info[info_offset + 6u];
    let img_type = info[info_offset + 7u];
    let width_height = info[info_offset + 8u];
    // The following are not intended to be bitcasts
    let x = f32(xy >> 16u);
    let y = f32(xy & 0xffffu);
    let width = f32(width_height >> 16u);
    let height = f32(width_height & 0xffffu);
    return CmdImage(matrx, xlat, vec2(x, y), vec2(width, height), img_type);
}

fn read_end_clip(cmd_ix: u32) -> CmdEndClip {
    let blend = ptcl[cmd_ix + 1u];
    let alpha = bitcast<f32>(ptcl[cmd_ix + 2u]);
    return CmdEndClip(blend, alpha);
}

let PIXELS_PER_THREAD = 4u;

fn fill_path(tile: Tile, xy: vec2<f32>, even_odd: bool, vre2d_hole:bool) -> array<f32, PIXELS_PER_THREAD> {
    var area: array<f32, PIXELS_PER_THREAD>;
    let backdrop_f = f32(tile.backdrop);
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        area[i] = backdrop_f;
    }
    var segment_ix = tile.segments;
    var time = 0u;
    var sum = 0.0;
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let y = segment.origin.y - xy.y;
        let y0 = clamp(y, 0.0, 1.0);
        let y1 = clamp(y + segment.delta.y, 0.0, 1.0);
        let dy = y0 - y1;
        sum += length(segment.delta);
        if dy != 0.0 {
            let vec_y_recip = 1.0 / segment.delta.y;
            let t0 = (y0 - y) * vec_y_recip;
            let t1 = (y1 - y) * vec_y_recip;
            let startx = segment.origin.x - xy.x;
            let x0 = startx + t0 * segment.delta.x;
            let x1 = startx + t1 * segment.delta.x;
            let xmin0 = min(x0, x1);
            let xmax0 = max(x0, x1);
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                let i_f = f32(i);
                let xmin = min(xmin0 - i_f, 1.0) - 1.0e-6;
                let xmax = xmax0 - i_f;
                let b = min(xmax, 1.0);
                let c = max(b, 0.0);
                let d = max(xmin, 0.0);
                let a = (b + 0.5 * (d * d - c * c) - xmin) / (xmax - xmin);
                area[i] += a * dy;
            }
        }
        let y_edge = sign(segment.delta.x) * clamp(xy.y - segment.y_edge + 1.0, 0.0, 1.0);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            area[i] += y_edge;
        }
        segment_ix = segment.next;
        time += 1u;
        if time >= 20u && sum <= 1.0{
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                area[i] = 0.0;
            }
            break;
        }
    }
    
    if even_odd {
        // even-odd winding rule
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            let a = area[i];
            area[i] = abs(a - 2.0 * round(0.5 * a));
        }
    } else if vre2d_hole{
        //vre2d hole rule
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            var a = area[i];
            if abs(a) > 1.001{
                a = ceil(a) * 2.0;
            }
            area[i] = abs(a - 2.0 * round(0.5 * a));
        }
    } else {
        // non-zero winding rule
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            area[i] = min(abs(area[i]), 1.0);
        }
    }
    
    return area;
}

fn stroke_path(seg: u32, half_width: f32, xy: vec2<f32>) -> array<f32, PIXELS_PER_THREAD> {
    var df: array<f32, PIXELS_PER_THREAD>;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        df[i] = 1e9;
    }
    var segment_ix = seg;
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let delta = segment.delta;
        let dpos0 = xy + vec2(0.5, 0.5) - segment.origin;
        let scale = 1.0 / dot(delta, delta);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            let dpos = vec2(dpos0.x + f32(i), dpos0.y);
            let t = clamp(dot(dpos, delta) * scale, 0.0, 1.0);
            // performance idea: hoist sqrt out of loop
            df[i] = min(df[i], length(delta * t - dpos));
        }
        segment_ix = segment.next;
    }
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        // reuse array; return alpha rather than distance
        df[i] = clamp(half_width + 0.5 - df[i], 0.0, 1.0);
    }
    return df;
}

// The X size should be 16 / PIXELS_PER_THREAD
@compute @workgroup_size(4, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2(f32(global_id.x * PIXELS_PER_THREAD), f32(global_id.y));

    var rgba: array<vec4<f32>, PIXELS_PER_THREAD>;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        rgba[i] = unpack4x8unorm(config.base_color).wzyx;
    }
    var blend_stack: array<array<u32, PIXELS_PER_THREAD>, BLEND_STACK_SPLIT>;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        for (var j = 0u; j < BLEND_STACK_SPLIT; j += 1u) {
            blend_stack[j][i] = 0u;
        }
    }
    var area: array<f32, PIXELS_PER_THREAD>;
    let tile_cmd_start_index = tile_ix * PTCL_INITIAL_ALLOC + 1u; // it's a const

    // STEP-1
    // get the end cmd index
    //↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
    var cmd_target = 0u;
    cmd_target = tile_cmd_start_index;
    // var iter_times = 0u;
    while true {
        let tag = ptcl[cmd_target];
        if tag == CMD_END {
            break;
        }
        // iter_times += 1u;
        switch tag {
            case 1u: {
                cmd_target += 3u;
            }
            case 2u: {
                cmd_target += 3u;
            }
            case 3u: {
                cmd_target += 1u;
            }
            case 5u: {
                cmd_target += 2u;
            }
            case 6u: {
                cmd_target += 3u;
            }
            case 7u: {
                cmd_target += 3u;
            }
            case 8u: {
                cmd_target += 2u;
            }
            case 9u: {
                cmd_target += 1u;
            }
            case 10u: {
                cmd_target += 3u;
            }
            case 11u: {
                cmd_target = ptcl[cmd_target + 1u];
            }
            default: {}
        }
    }

    // if it already ends(CMD_END) then render directly
    // which never happends in our testcase, since we have layer(clip)
    if (cmd_target == tile_cmd_start_index) {
        let xy_uint = vec2<u32>(xy);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            let coords = xy_uint + vec2(i, 0u);
            if coords.x < config.target_width && coords.y < config.target_height {
                let fg = rgba[i];
                // Max with a small epsilon to avoid NaNs
                // let a_inv = 1.0 / max(fg.a, 1e-6);
                // let rgba_sep = vec4(fg.rgb * a_inv, fg.a);
                let rgba_sep = vec4(1.0, 0.0, 0.0, 1.0);
                textureStore(output, vec2<i32>(coords), rgba_sep);
            }
        } 
        return;
    }
    //↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑

    // reverse fetching the last cmd as we need
    // STEP-2 init all data, we got CMD_LENGTH items, we only need the last CMD_LENGTH cmds at most
    //↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
    var reverseItemArray: array <ReverseItem, CMD_LENGTH>;
    for (var j = 0u; j < CMD_LENGTH; j += 1u) {
        reverseItemArray[j].clip_depth = 0u;
        reverseItemArray[j].cmd_tag = 0u;
        reverseItemArray[j].clip_end_cmd_ix = 0u;
        reverseItemArray[j].status = 0u;
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            reverseItemArray[j].area[i] = 0.0;
            reverseItemArray[j].rgba[i] = vec4(0.0);
        }
    }
    //↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑    
    // STEP-3 init all data
    //↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
    
    // indicates how many commands we have gathered, which could be less than CMD_LENGTH
    var filled_cmd_index = 0u; 
    
    // indicates the current depth of a clip range
    var reverse_clip_depth = 0u;

    // since we need to ge the blend mode and the clip are, 
    // so we need to know cmd index to fetch the CmdEndClip 
    var clip_end_cmd_idx = 0u;

    // At first I thought if the alpha value we got from back to front is already 1.0, 
    // then the following cmds are totally useless, I mean just return the whole ptcl,
    // However, this is only useful when the clip depth is 0, which means there is no clip at all

    // But we still need something called 
    // var alpha_sum = vec4(false) 
    // this could be useful to skip the CMDs in the same clip layer
    var alpha_sum = vec4(false);

    // after we finish processing the cmd, we tell if we should quit the outer while loop
    // case-1: we already meet the first cmd
    // var iter_times = 0u;
    while (cmd_target != tile_cmd_start_index) {
        var last_cmd = tile_cmd_start_index; 
        
        // cmd_ix initial start position
        // cmd_target is the last time end position
        // last_cmd is the current end position we are looking for，
        // which is the second last cmd, I know this while loop looks stupid, we can looking for a 
        // better way in the future, such as array or double linked list in PTCL
        // NOTE: this stupic "LOOKING FOR THE SECOND LAST COMMAND_INDEX" is the most time consuming part!!!!!!
        while true {
            let tag = ptcl[last_cmd];
            var offset = 0u;
            var jump_cmd = 0u;
            switch tag {
                case 1u: {
                    offset = 3u;
                }
                case 2u: {
                    offset = 3u;
                }
                case 3u: {
                    offset = 1u;
                }
                case 5u: {
                    offset = 2u;
                }
                case 9u: {
                    offset = 1u;
                }
                case 10u: {
                    offset = 3u;
                }
                case 11u: {
                    offset = ptcl[last_cmd + 1u] - last_cmd;
                }
                default: {}
            }
            last_cmd += offset;
            if last_cmd == cmd_target {
                cmd_target -= offset;
                break;
            }
        }

        // iter_times += 1u;
        // let tag = ptcl[cmd_target];
        // if (iter_times == 88u) {
        //     if (tag == 1u) {
        //         rgba[0u] = vec4(1.0, 0.0, 0.0, 1.0);
        //         rgba[1u] = vec4(1.0, 0.0, 0.0, 1.0);
        //         rgba[2u] = vec4(1.0, 0.0, 0.0, 1.0);
        //         rgba[3u] = vec4(1.0, 0.0, 0.0, 1.0);
        //     } else if (tag == 2u) {
        //         rgba[0u] = vec4(0.0, 1.0, 0.0, 1.0);
        //         rgba[1u] = vec4(0.0, 1.0, 0.0, 1.0);
        //         rgba[2u] = vec4(0.0, 1.0, 0.0, 1.0);
        //         rgba[3u] = vec4(0.0, 1.0, 0.0, 1.0);
        //     } else if (tag == 3u) {
        //         rgba[0u] = vec4(0.0, 0.0, 1.0, 1.0);
        //         rgba[1u] = vec4(0.0, 0.0, 1.0, 1.0);
        //         rgba[2u] = vec4(0.0, 0.0, 1.0, 1.0);
        //         rgba[3u] = vec4(0.0, 0.0, 1.0, 1.0);
        //     } else if (tag == 5u) {
        //         rgba[0u] = vec4(1.0, 1.0, 0.0, 1.0);
        //         rgba[1u] = vec4(1.0, 1.0, 0.0, 1.0);
        //         rgba[2u] = vec4(1.0, 1.0, 0.0, 1.0);
        //         rgba[3u] = vec4(1.0, 1.0, 0.0, 1.0);
        //     } else if (tag == 9u) {
        //         rgba[0u] = vec4(0.0, 1.0, 1.0, 1.0);
        //         rgba[1u] = vec4(0.0, 1.0, 1.0, 1.0);
        //         rgba[2u] = vec4(0.0, 1.0, 1.0, 1.0);
        //         rgba[3u] = vec4(0.0, 1.0, 1.0, 1.0);
        //     } else if (tag == 10u) {
        //         rgba[0u] = vec4(1.0, 0.0, 1.0, 1.0);
        //         rgba[1u] = vec4(1.0, 0.0, 1.0, 1.0);
        //         rgba[2u] = vec4(1.0, 0.0, 1.0, 1.0);
        //         rgba[3u] = vec4(1.0, 0.0, 1.0, 1.0);
        //     } else if (tag == 11u) {
        //         rgba[0u] = vec4(0.0, 0.5, 0.0, 1.0);
        //         rgba[1u] = vec4(0.0, 0.5, 0.0, 1.0);
        //         rgba[2u] = vec4(0.0, 0.5, 0.0, 1.0);
        //         rgba[3u] = vec4(0.0, 0.5, 0.0, 1.0);
        //     } else {
        //         rgba[0u] = vec4(0.0, 0.0, 0.5, 1.0);
        //         rgba[1u] = vec4(0.0, 0.0, 0.5, 1.0);
        //         rgba[2u] = vec4(0.0, 0.0, 0.5, 1.0);
        //         rgba[3u] = vec4(0.0, 0.0, 0.5, 1.0);
        //     }
        //     let xy_uint = vec2<u32>(xy);
        //     for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        //         let coords = xy_uint + vec2(i, 0u);
        //         if coords.x < config.target_width && coords.y < config.target_height {
        //             let fg = rgba[i];
        //             // Max with a small epsilon to avoid NaNs
        //             let a_inv = 1.0 / max(fg.a, 1e-6);
        //             let rgba_sep = vec4(fg.rgb * a_inv, fg.a);
        //             textureStore(output, vec2<i32>(coords), rgba_sep);
        //         }
        //     } 
        //     return;
        // }
        
        // if it's CMD_JUMP then just skip it
        if (ptcl[cmd_target] != 11u) {
            // now we get the last command we need,which been saved into cmd_target
            // we analysis the command here
            let tag = ptcl[cmd_target];
            switch tag {
                // CMD_FILL
                case 1u: {
                    if (reverseItemArray[filled_cmd_index].status & 1u) == 0u { // area not filled
                        let fill = read_fill(cmd_target);
                        let segments = fill.tile >> 2u;
                        let even_odd = (fill.tile & 1u) != 0u;
                        let vre2d_hole = (fill.tile & 2u) != 0u;
                        let tile = Tile(fill.backdrop, segments);
                        reverseItemArray[filled_cmd_index].area = fill_path(tile, xy, even_odd, vre2d_hole);
                        reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 1u;
                    }
                }
                // CMD_STROKE
                case 2u: {
                    if (reverseItemArray[filled_cmd_index].status & 1u) == 0u { // area not filled
                        let stroke = read_stroke(cmd_target);
                        reverseItemArray[filled_cmd_index].area = stroke_path(stroke.tile, stroke.half_width, xy);
                        reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 1u;
                    }
                }
                // CMD_SOLID
                case 3u: { 
                    if (reverseItemArray[filled_cmd_index].status & 1u) == 0u { // area not filled
                        reverseItemArray[filled_cmd_index].area[0] = 1.0;
                        reverseItemArray[filled_cmd_index].area[1] = 1.0;
                        reverseItemArray[filled_cmd_index].area[2] = 1.0;
                        reverseItemArray[filled_cmd_index].area[3] = 1.0;
                        reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 1u;
                    }
                }
                // CMD_COLOR
                case 5u: {
                    if (reverseItemArray[filled_cmd_index].status & 2u) == 0u { // rgba not filled
                        let color = read_color(cmd_target);
                        reverseItemArray[filled_cmd_index].cmd_tag = 5u;
                        reverseItemArray[filled_cmd_index].rgba[0u] = unpack4x8unorm(color.rgba_color).wzyx;
                        reverseItemArray[filled_cmd_index].rgba[1u] = reverseItemArray[filled_cmd_index].rgba[0u];
                        reverseItemArray[filled_cmd_index].rgba[2u] = reverseItemArray[filled_cmd_index].rgba[0u];
                        reverseItemArray[filled_cmd_index].rgba[3u] = reverseItemArray[filled_cmd_index].rgba[0u];
                        reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 2u;
                    }
                }
                default: {}
            }
            
            // if area and color are ready
            if reverseItemArray[filled_cmd_index].status == 3u { // both area and color are ready
                if !(all(alpha_sum)) { // not all the 4 alphaa are 1
                    var alpha_combine = vec4(0.0);
                    alpha_combine[0u] = reverseItemArray[filled_cmd_index].area[0u] * reverseItemArray[filled_cmd_index].rgba[0u].a;
                    alpha_combine[1u] = reverseItemArray[filled_cmd_index].area[1u] * reverseItemArray[filled_cmd_index].rgba[1u].a;
                    alpha_combine[2u] = reverseItemArray[filled_cmd_index].area[2u] * reverseItemArray[filled_cmd_index].rgba[2u].a;
                    alpha_combine[3u] = reverseItemArray[filled_cmd_index].area[3u] * reverseItemArray[filled_cmd_index].rgba[3u].a;
                    
                    if alpha_combine[0u] < 0.005 && 
                       alpha_combine[1u] < 0.005 &&
                       alpha_combine[2u] < 0.005 &&
                       alpha_combine[3u] < 0.005 {
                        // just skip this area-rgba combo since they don't do anything useful
                        // reset it first
                        reverseItemArray[filled_cmd_index].cmd_tag = 0u;
                        reverseItemArray[filled_cmd_index].status = 0u;
                        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                            reverseItemArray[filled_cmd_index].area[i] = 0.0;
                            reverseItemArray[filled_cmd_index].rgba[i] = vec4(0.0);
                        }
                    } else {
                        // set up the clip depth
                        reverseItemArray[filled_cmd_index].clip_depth = reverse_clip_depth;

                        // keep checking if the alphas are opaque
                        // please plase use some smarter inner functions, the following code are so so so ugly!
                        if (alpha_sum[0u] == false) {
                            if (reverseItemArray[filled_cmd_index].area[0u] * reverseItemArray[filled_cmd_index].rgba[0u].a > 0.995) {
                                alpha_sum[0u] = true;
                            }
                        }

                        if (alpha_sum[1u] == false) {
                            if (reverseItemArray[filled_cmd_index].area[1u] * reverseItemArray[filled_cmd_index].rgba[1u].a  > 0.995) {
                                alpha_sum[1u] = true;
                            }
                        }

                        if (alpha_sum[2u] == false) {
                            if (reverseItemArray[filled_cmd_index].area[2u] * reverseItemArray[filled_cmd_index].rgba[2u].a  > 0.995) {
                                alpha_sum[2u] = true;
                            }
                        }

                        if (alpha_sum[3u] == false) {
                            if (reverseItemArray[filled_cmd_index].area[3u] * reverseItemArray[filled_cmd_index].rgba[3u].a  > 0.995) {
                                alpha_sum[3u] = true;
                            }
                        }

                        if (!all(alpha_sum)) {
                            // after we finish processing the cmd, we tell if we should quit the outer while loop
                            // case-3: we already fill the CMD_LENGTH commonds list full
                            if (filled_cmd_index + 1u) == CMD_LENGTH {
                                break;
                            }
                            // we go to the next
                            filled_cmd_index += 1u;
                        }
                    }
                }
            }
 
            if tag == 9u { // CMD_BEGIN_CLIP
                alpha_sum = vec4(false);
                // if the current position is not used for any other thing, we just use it
                if reverseItemArray[filled_cmd_index].status != 0u { // the current one is used for something else alread
                    // go to next
                    if (filled_cmd_index + 1u) == CMD_LENGTH {
                        break;
                    }
                    filled_cmd_index += 1u;
                }
                reverseItemArray[filled_cmd_index].clip_depth = reverse_clip_depth;
                reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 8u;
                
                if (filled_cmd_index + 1u) == CMD_LENGTH {
                    break;
                }
                // go to next
                filled_cmd_index += 1u;
                // minus here
                reverse_clip_depth -= 1u;
            } else if tag == 10u {      // CMD_END_CLIP
                reverse_clip_depth += 1u;
                alpha_sum = vec4(false);
                if reverseItemArray[filled_cmd_index].status != 0u { // the current one is used for something else alread
                    // go to next
                    if (filled_cmd_index + 1u) == CMD_LENGTH {
                        break;
                    }
                    filled_cmd_index += 1u;
                }
                reverseItemArray[filled_cmd_index].clip_depth = reverse_clip_depth;
                reverseItemArray[filled_cmd_index].clip_end_cmd_ix = cmd_target;
                reverseItemArray[filled_cmd_index].status = reverseItemArray[filled_cmd_index].status | 4u;
            }

            if reverseItemArray[filled_cmd_index].status == 5u { // 0b = 00101, both clip end and area are ready
                if (filled_cmd_index + 1u) == CMD_LENGTH {
                    break;
                }
                filled_cmd_index += 1u;
            }
        }
    }

    // if we over step to next cmd but did do anything, back 1 step
    if (reverseItemArray[filled_cmd_index].status == 0u) {
        filled_cmd_index -= 1u;
    }

    for (var j = 0u; j < filled_cmd_index + 1u ; j += 1u) {
        let item = reverseItemArray[filled_cmd_index - j];

        // if it's begin clip
        if item.status == 8u {
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                blend_stack[item.clip_depth - 1u][i] = pack4x8unorm(rgba[i]);
                rgba[i] = vec4(0.0);
            }
        } else if (j == 0u && item.clip_depth > 0u) {
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                blend_stack[item.clip_depth - 1u][i] = pack4x8unorm(rgba[i]);
                rgba[i] = vec4(0.0);
            }
        }
        // NOTE：the upper if cases are doing the same thing, but for make it easier to understand
        // I seperated them, we can combine thees two into one later

        // CMD_FILL CMD_STROKE CMD_SOLID only decide the area, which we have dealed with before
        // here we only care about the rgba, also CMD_LIN_GRAD CMD_RAD_GRAD CMD_IMAGE never used in out case, skip them first
        // as to the BEGIN and END CLIP, we process it in the beginning and ending
        switch item.cmd_tag {
            // CMD_COLOR
            case 5u: {
                area[0u] = item.area[0u];
                var fg_i = item.rgba[0u] * area[0u];
                rgba[0u] = rgba[0u] * (1.0 - fg_i.a) + fg_i;

                area[1u] = item.area[1u];
                fg_i = item.rgba[1u] * area[1u];
                rgba[1u] = rgba[1u] * (1.0 - fg_i.a) + fg_i;

                area[2u] = item.area[2u];
                fg_i = item.rgba[2u] * area[2u];
                rgba[2u] = rgba[2u] * (1.0 - fg_i.a) + fg_i;

                area[3u] = item.area[3u];
                fg_i = item.rgba[3u] * area[3u];
                rgba[3u] = rgba[3u] * (1.0 - fg_i.a) + fg_i;
            }
            default: {}
        }

        // if it's end clip. All the endclip should also be area ready, so it's 0b- 00101
        if item.status == 5u {
            let end_clip = read_end_clip(item.clip_end_cmd_ix);

            var bg_rgba = blend_stack[item.clip_depth - 1u][0u];
            var bg = unpack4x8unorm(bg_rgba);
            var fg = rgba[0u] * item.area[0u] * end_clip.alpha;
            rgba[0u] = blend_mix_compose(bg, fg, end_clip.blend);

            bg_rgba = blend_stack[item.clip_depth - 1u][1u];
            bg = unpack4x8unorm(bg_rgba);
            fg = rgba[1u] * item.area[1u] * end_clip.alpha;
            rgba[1u] = blend_mix_compose(bg, fg, end_clip.blend);

            bg_rgba = blend_stack[item.clip_depth - 1u][2u];
            bg = unpack4x8unorm(bg_rgba);
            fg = rgba[2u] * item.area[2u] * end_clip.alpha;
            rgba[2u] = blend_mix_compose(bg, fg, end_clip.blend);


            bg_rgba = blend_stack[item.clip_depth - 1u][3u];
            bg = unpack4x8unorm(bg_rgba);
            fg = rgba[3u] * item.area[3u] * end_clip.alpha;
            rgba[3u] = blend_mix_compose(bg, fg, end_clip.blend);
        } 
        // NOTE：the upper if cases are doing the same thing, but for make it easier to understand
        // I seperated them, we can combine thees two into one later
    }

    let xy_uint = vec2<u32>(xy);
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        let coords = xy_uint + vec2(i, 0u);
        if coords.x < config.target_width && coords.y < config.target_height {
            let fg = rgba[i];
            // Max with a small epsilon to avoid NaNs
            let a_inv = 1.0 / max(fg.a, 1e-6);
            let rgba_sep = vec4(fg.rgb * a_inv, fg.a);
            textureStore(output, vec2<i32>(coords), rgba_sep);
        }
    } 
}

fn premul_alpha(rgba: vec4<f32>) -> vec4<f32> {
    return vec4(rgba.rgb * rgba.a, rgba.a);
}
