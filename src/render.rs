//! Take an encoded scene and create a graph to render it

use crate::{
    engine::{BufProxy, ImageFormat, ImageProxy, Recording, ResourceProxy},
    shaders::FullShaders,
    RenderParams, Scene,
};
use vello_encoding::{Encoding, WorkgroupSize};

/// State for a render in progress.
pub struct Render {
    fine_wg_count: Option<WorkgroupSize>,
    fine_resources: Option<FineResources>,
}

/// Resources produced by pipeline, needed for fine rasterization.
struct FineResources {
    config_buf: ResourceProxy,
    bump_buf: ResourceProxy,
    tile_buf: ResourceProxy,
    segments_buf: ResourceProxy,
    ptcl_buf: ResourceProxy,
    gradient_image: ResourceProxy,
    info_bin_data_buf: ResourceProxy,
    image_atlas: ResourceProxy,

    out_image: ImageProxy,
}

pub fn render_full(
    scene: &Scene,
    shaders: &FullShaders,
    params: &RenderParams,
) -> (Recording, ResourceProxy) {
    render_encoding_full(scene.data(), shaders, params)
}

/// Create a single recording with both coarse and fine render stages.
///
/// This function is not recommended when the scene can be complex, as it does not
/// implement robust dynamic memory.
pub fn render_encoding_full(
    encoding: &Encoding,
    shaders: &FullShaders,
    params: &RenderParams,
) -> (Recording, ResourceProxy) {
    let mut render = Render::new();
    let mut recording = render.render_encoding_coarse(encoding, shaders, params, false);
    let out_image = render.out_image();
    render.record_fine(shaders, &mut recording);
    (recording, out_image.into())
}

impl Render {
    pub fn new() -> Self {
        Render {
            fine_wg_count: None,
            fine_resources: None,
        }
    }

    /// Prepare a recording for the coarse rasterization phase.
    ///
    /// The `robust` parameter controls whether we're preparing for readback
    /// of the atomic bump buffer, for robust dynamic memory.
    pub fn render_encoding_coarse(
        &mut self,
        encoding: &Encoding,
        shaders: &FullShaders,
        params: &RenderParams,
        robust: bool,
    ) -> Recording {
        use vello_encoding::{RenderConfig, Resolver};

        let mut recording = Recording::default();
        let mut resolver = Resolver::new();
        let mut packed = vec![];
        let (layout, ramps, images) = resolver.resolve(encoding, &mut packed);
        let gradient_image = if ramps.height == 0 {
            ResourceProxy::new_image(1, 1, ImageFormat::Rgba8)
        } else {
            let data: &[u8] = bytemuck::cast_slice(ramps.data);
            ResourceProxy::Image(recording.upload_image(
                ramps.width,
                ramps.height,
                ImageFormat::Rgba8,
                data,
            ))
        };
        let image_atlas = if images.images.is_empty() {
            ImageProxy::new(1, 1, ImageFormat::Rgba8)
        } else {
            ImageProxy::new(images.width, images.height, ImageFormat::Rgba8)
        };
        for image in images.images {
            recording.write_image(
                image_atlas,
                image.1,
                image.2,
                image.0.width,
                image.0.height,
                image.0.data.data(),
            );
        }

        let cpu_config =
            RenderConfig::new(&layout, params.width, params.height, &params.base_color, encoding.camera_transform);
        let buffer_sizes = &cpu_config.buffer_sizes;
        let wg_counts = &cpu_config.workgroup_counts;

        let scene_buf = ResourceProxy::Buf(recording.upload("scene", packed));
        let config_buf = ResourceProxy::Buf(
            recording.upload_uniform("config", bytemuck::bytes_of(&cpu_config.gpu)),
        );
        let info_bin_data_buf = ResourceProxy::new_buf(
            buffer_sizes.bin_data.size_in_bytes() as u64,
            "info_bin_data_buf",
        );
        let tile_buf =
            ResourceProxy::new_buf(buffer_sizes.tiles.size_in_bytes().into(), "tile_buf");
        let segments_buf =
            ResourceProxy::new_buf(buffer_sizes.segments.size_in_bytes().into(), "segments_buf");
        let ptcl_buf = ResourceProxy::new_buf(buffer_sizes.ptcl.size_in_bytes().into(), "ptcl_buf");
        let reduced_buf = ResourceProxy::new_buf(
            buffer_sizes.path_reduced.size_in_bytes().into(),
            "reduced_buf",
        );
        // TODO: really only need pathtag_wgs - 1
        recording.dispatch(
            shaders.pathtag_reduce,
            wg_counts.path_reduce,
            [config_buf, scene_buf, reduced_buf],
        );
        let mut pathtag_parent = reduced_buf;
        let mut large_pathtag_bufs = None;
        if wg_counts.use_large_path_scan {
            let reduced2_buf = ResourceProxy::new_buf(
                buffer_sizes.path_reduced2.size_in_bytes().into(),
                "reduced2_buf",
            );
            recording.dispatch(
                shaders.pathtag_reduce2,
                wg_counts.path_reduce2,
                [reduced_buf, reduced2_buf],
            );
            let reduced_scan_buf = ResourceProxy::new_buf(
                buffer_sizes.path_reduced_scan.size_in_bytes().into(),
                "reduced_scan_buf",
            );
            recording.dispatch(
                shaders.pathtag_scan1,
                wg_counts.path_scan1,
                [reduced_buf, reduced2_buf, reduced_scan_buf],
            );
            pathtag_parent = reduced_scan_buf;
            large_pathtag_bufs = Some((reduced2_buf, reduced_scan_buf));
        }

        let tagmonoid_buf = ResourceProxy::new_buf(
            buffer_sizes.path_monoids.size_in_bytes().into(),
            "tagmonoid_buf",
        );
        let pathtag_scan = if wg_counts.use_large_path_scan {
            shaders.pathtag_scan_large
        } else {
            shaders.pathtag_scan
        };
        recording.dispatch(
            pathtag_scan,
            wg_counts.path_scan,
            [config_buf, scene_buf, pathtag_parent, tagmonoid_buf],
        );
        recording.free_resource(reduced_buf);
        if let Some((reduced2, reduced_scan)) = large_pathtag_bufs {
            recording.free_resource(reduced2);
            recording.free_resource(reduced_scan);
        }
        let path_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.path_bboxes.size_in_bytes().into(),
            "path_bbox_buf",
        );
        recording.dispatch(
            shaders.bbox_clear,
            wg_counts.bbox_clear,
            [config_buf, path_bbox_buf],
        );
        let cubic_buf =
            ResourceProxy::new_buf(buffer_sizes.cubics.size_in_bytes().into(), "cubic_buf");
        recording.dispatch(
            shaders.pathseg,
            wg_counts.path_seg,
            [
                config_buf,
                scene_buf,
                tagmonoid_buf,
                path_bbox_buf,
                cubic_buf,
            ],
        );
        let draw_reduced_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_reduced.size_in_bytes().into(),
            "draw_reduced_buf",
        );
        recording.dispatch(
            shaders.draw_reduce,
            wg_counts.draw_reduce,
            [config_buf, scene_buf, draw_reduced_buf],
        );
        let draw_monoid_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_monoids.size_in_bytes().into(),
            "draw_monoid_buf",
        );
        let clip_inp_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_inps.size_in_bytes().into(),
            "clip_inp_buf",
        );
        let path_to_pattern_buf = ResourceProxy::new_buf(
            buffer_sizes.path_to_pattern.size_in_bytes().into(),
            "path_to_pattern_buf",
        );
        let bump_buf = BufProxy::new(buffer_sizes.bump_alloc.size_in_bytes().into(), "bump_buf");
        recording.dispatch(
            shaders.draw_leaf,
            wg_counts.draw_leaf,
            [
                config_buf,
                scene_buf,
                draw_reduced_buf,
                path_bbox_buf,
                draw_monoid_buf,
                info_bin_data_buf,
                clip_inp_buf,
                path_to_pattern_buf,
            ],
        );
        recording.free_resource(draw_reduced_buf);
        let clip_el_buf =
            ResourceProxy::new_buf(buffer_sizes.clip_els.size_in_bytes().into(), "clip_el_buf");
        let clip_bic_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_bics.size_in_bytes().into(),
            "clip_bic_buf",
        );
        if wg_counts.clip_reduce.0 > 0 {
            recording.dispatch(
                shaders.clip_reduce,
                wg_counts.clip_reduce,
                [
                    config_buf,
                    clip_inp_buf,
                    path_bbox_buf,
                    clip_bic_buf,
                    clip_el_buf,
                ],
            );
        }
        let clip_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_bboxes.size_in_bytes().into(),
            "clip_bbox_buf",
        );
        if wg_counts.clip_leaf.0 > 0 {
            recording.dispatch(
                shaders.clip_leaf,
                wg_counts.clip_leaf,
                [
                    config_buf,
                    clip_inp_buf,
                    path_bbox_buf,
                    clip_bic_buf,
                    clip_el_buf,
                    draw_monoid_buf,
                    clip_bbox_buf,
                ],
            );
        }
        recording.free_resource(clip_inp_buf);
        recording.free_resource(clip_bic_buf);
        recording.free_resource(clip_el_buf);

        let indirect_count_buf = BufProxy::new(
            buffer_sizes.indirect_count.size_in_bytes().into(),
            "indirect_count",
        );

        
        if wg_counts.use_patterns{
            let camera_buf = ResourceProxy::Buf(
                recording.upload_uniform("camera", bytemuck::bytes_of(&cpu_config.camera_transform)),
            );
            recording.dispatch(
                shaders.path_count_setup,
                (1, 1, 1),
                [bump_buf, indirect_count_buf.into()],
            );
            recording.dispatch_indirect(
                shaders.pattern,
                indirect_count_buf,
                0,
                [
                    config_buf,
                    camera_buf,
                    scene_buf,
                    clip_bbox_buf,
                    path_to_pattern_buf,
                    path_bbox_buf,
                    bump_buf,
                    lines_buf,
                ],
            );
        }
        recording.free_resource(path_to_pattern_buf);

        let draw_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_bboxes.size_in_bytes().into(),
            "draw_bbox_buf",
        );

        let bin_header_buf = ResourceProxy::new_buf(
            buffer_sizes.bin_headers.size_in_bytes().into(),
            "bin_header_buf",
        );
        recording.clear_all(bump_buf);
        let bump_buf = ResourceProxy::Buf(bump_buf);
        recording.dispatch(
            shaders.binning,
            wg_counts.binning,
            [
                config_buf,
                draw_monoid_buf,
                path_bbox_buf,
                clip_bbox_buf,
                draw_bbox_buf,
                bump_buf,
                info_bin_data_buf,
                bin_header_buf,
            ],
        );
        recording.free_resource(draw_monoid_buf);
        recording.free_resource(path_bbox_buf);
        recording.free_resource(clip_bbox_buf);
        // Note: this only needs to be rounded up because of the workaround to store the tile_offset
        // in storage rather than workgroup memory.
        let path_buf =
            ResourceProxy::new_buf(buffer_sizes.paths.size_in_bytes().into(), "path_buf");
        recording.dispatch(
            shaders.tile_alloc,
            wg_counts.tile_alloc,
            [
                config_buf,
                scene_buf,
                draw_bbox_buf,
                bump_buf,
                path_buf,
                tile_buf,
            ],
        );
        recording.free_resource(draw_bbox_buf);
        recording.dispatch(
            shaders.path_coarse,
            wg_counts.path_coarse,
            [
                config_buf,
                scene_buf,
                tagmonoid_buf,
                cubic_buf,
                path_buf,
                bump_buf,
                tile_buf,
                segments_buf,
            ],
        );
        recording.free_resource(tagmonoid_buf);
        recording.free_resource(cubic_buf);
        recording.dispatch(
            shaders.backdrop,
            wg_counts.backdrop,
            [config_buf, path_buf, tile_buf],
        );
        recording.dispatch(
            shaders.coarse,
            wg_counts.coarse,
            [
                config_buf,
                scene_buf,
                draw_monoid_buf,
                bin_header_buf,
                info_bin_data_buf,
                path_buf,
                tile_buf,
                bump_buf,
                ptcl_buf,
            ],
        );
        recording.free_resource(scene_buf);
        recording.free_resource(draw_monoid_buf);
        recording.free_resource(bin_header_buf);
        recording.free_resource(path_buf);
        let out_image = ImageProxy::new(params.width, params.height, ImageFormat::Rgba8);
        self.fine_wg_count = Some(wg_counts.fine);
        self.fine_resources = Some(FineResources {
            config_buf,
            bump_buf,
            tile_buf,
            segments_buf,
            ptcl_buf,
            gradient_image,
            info_bin_data_buf,
            image_atlas: ResourceProxy::Image(image_atlas),
            out_image,
        });
        if robust {
            recording.download(*bump_buf.as_buf().unwrap());
        }
        recording.free_resource(bump_buf);
        recording
    }

    /// Run fine rasterization assuming the coarse phase succeeded.
    pub fn record_fine(&mut self, shaders: &FullShaders, recording: &mut Recording) {
        let fine_wg_count = self.fine_wg_count.take().unwrap();
        let fine = self.fine_resources.take().unwrap();
        recording.dispatch(
            shaders.fine,
            fine_wg_count,
            [
                fine.config_buf,
                fine.tile_buf,
                fine.segments_buf,
                ResourceProxy::Image(fine.out_image),
                fine.ptcl_buf,
                fine.gradient_image,
                fine.info_bin_data_buf,
                fine.image_atlas,
            ],
        );
        recording.free_resource(fine.config_buf);
        recording.free_resource(fine.tile_buf);
        recording.free_resource(fine.segments_buf);
        recording.free_resource(fine.ptcl_buf);
        recording.free_resource(fine.gradient_image);
        recording.free_resource(fine.image_atlas);
        recording.free_resource(fine.info_bin_data_buf);
    }

    /// Get the output image.
    ///
    /// This is going away, as the caller will add the output image to the bind
    /// map.
    pub fn out_image(&self) -> ImageProxy {
        self.fine_resources.as_ref().unwrap().out_image
    }

    pub fn bump_buf(&self) -> BufProxy {
        *self
            .fine_resources
            .as_ref()
            .unwrap()
            .bump_buf
            .as_buf()
            .unwrap()
    }
}
