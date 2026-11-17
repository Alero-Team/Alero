//! 2D drawing for the island: squircle shapes, text, icons, images and a box blur, all on the CPU.
//!
//! Everything is expressed in *logical* units; the canvas multiplies them by `k` (display scale × the user's size
//! setting) when it touches pixels. The pixel format is tiny-skia's: premultiplied RGBA8.

use std::collections::HashMap;
use std::f32::consts::{FRAC_PI_2, PI};

use ab_glyph::{Font, FontRef, FontVec, GlyphId, PxScale, ScaleFont};
use tiny_skia::{
    BlendMode, Color, FillRule, FilterQuality, LineCap, LineJoin, Mask, Paint, Path, PathBuilder, Pattern, Pixmap, PixmapPaint, SpreadMode,
    Stroke, Transform,
};

pub type Rgb = [u8; 3];

/// A rectangle in logical units.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct R {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl R {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }
    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
    pub fn right(&self) -> f32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }
    pub fn cx(&self) -> f32 {
        self.x + self.w / 2.0
    }
    pub fn cy(&self) -> f32 {
        self.y + self.h / 2.0
    }
    pub fn inflate(&self, d: f32) -> R {
        R::new(self.x - d, self.y - d, self.w + 2.0 * d, self.h + 2.0 * d)
    }
    /// Cuts `l, t, r, b` off the sides.
    pub fn inset(&self, l: f32, t: f32, r: f32, b: f32) -> R {
        R::new(self.x + l, self.y + t, (self.w - l - r).max(0.0), (self.h - t - b).max(0.0))
    }
}

pub fn color(c: Rgb, alpha: f32) -> Color {
    Color::from_rgba8(c[0], c[1], c[2], (alpha.clamp(0.0, 1.0) * 255.0).round() as u8)
}

pub fn mix(a: Rgb, b: Rgb, t: f32) -> Rgb {
    let m = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t.clamp(0.0, 1.0)).round() as u8;
    [m(a[0], b[0]), m(a[1], b[1]), m(a[2], b[2])]
}

/// The outline of a rectangle with continuous ("squircle") corners, like the iPhone's. `n` is the exponent of the
/// superellipse used for each corner: 2 is a circle, higher is squarer.
pub fn squircle(r: R, radius: f32, n: f32) -> Option<Path> {
    let radius = radius.min(r.w / 2.0).min(r.h / 2.0).max(0.0);
    let mut pb = PathBuilder::new();
    if radius < 0.5 {
        pb.push_rect(tiny_skia::Rect::from_xywh(r.x, r.y, r.w.max(0.1), r.h.max(0.1))?);
        return pb.finish();
    }
    let steps = ((radius * 1.2) as usize).clamp(10, 40);
    let e = 2.0 / n;
    // (corner centre, first angle): top-right, bottom-right, bottom-left, top-left.
    let corners = [(r.right() - radius, r.y + radius, -FRAC_PI_2), (r.right() - radius, r.bottom() - radius, 0.0), (r.x + radius, r.bottom() - radius, FRAC_PI_2), (r.x + radius, r.y + radius, PI)];
    let mut first = true;
    for (cx, cy, a0) in corners {
        for i in 0..=steps {
            let a = a0 + FRAC_PI_2 * i as f32 / steps as f32;
            let (s, c) = a.sin_cos();
            let (px, py) = (cx + radius * c.signum() * c.abs().powf(e), cy + radius * s.signum() * s.abs().powf(e));
            if first {
                pb.move_to(px, py);
                first = false;
            } else {
                pb.line_to(px, py);
            }
        }
    }
    pb.close();
    pb.finish()
}

/// Exponent that looks right for a corner of this radius on a shape of this height: a capsule is rounder than a card.
pub fn squircle_n(radius: f32, height: f32) -> f32 {
    let t = (radius / (height / 2.0).max(1.0)).clamp(0.0, 1.0);
    4.6 - 2.2 * t * t
}

// ---------------------------------------------------------------------------------------------------------
// Images

/// A decoded picture: premultiplied RGBA8.
#[derive(Clone)]
pub struct Image {
    pub w: u32,
    pub h: u32,
    pub data: Vec<u8>,
}

impl Image {
    fn from_rgba(w: u32, h: u32, rgba: Vec<u8>) -> Option<Image> {
        if w == 0 || h == 0 || rgba.len() != (w * h * 4) as usize {
            return None;
        }
        let img = Image { w, h, data: rgba };
        Some(img.shrunk(192).premultiplied())
    }

    fn premultiplied(mut self) -> Image {
        for p in self.data.chunks_exact_mut(4) {
            let a = p[3] as u32;
            if a != 255 {
                for c in &mut p[..3] {
                    *c = ((*c as u32 * a + 127) / 255) as u8;
                }
            }
        }
        self
    }

    /// Averages blocks so the longest side is at most `max`: covers can be 1000 px, the island shows 100.
    fn shrunk(self, max: u32) -> Image {
        let f = (self.w.max(self.h) / max).max(1);
        if f == 1 {
            return self;
        }
        let (nw, nh) = (self.w / f, self.h / f);
        let mut out = vec![0u8; (nw * nh * 4) as usize];
        for y in 0..nh {
            for x in 0..nw {
                let mut acc = [0u32; 4];
                for dy in 0..f {
                    for dx in 0..f {
                        let i = (((y * f + dy) * self.w + x * f + dx) * 4) as usize;
                        for c in 0..4 {
                            acc[c] += self.data[i + c] as u32;
                        }
                    }
                }
                let o = ((y * nw + x) * 4) as usize;
                for c in 0..4 {
                    out[o + c] = (acc[c] / (f * f)) as u8;
                }
            }
        }
        Image { w: nw, h: nh, data: out }
    }
}

/// PNG or JPEG bytes (a cover, an app icon) to an image.
pub fn decode_image(bytes: &[u8]) -> Option<Image> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
        dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut r = dec.read_info().ok()?;
        let mut buf = vec![0; r.output_buffer_size()?];
        let info = r.next_frame(&mut buf).ok()?;
        buf.truncate(info.buffer_size());
        let rgba: Vec<u8> = match info.color_type {
            png::ColorType::Rgba => buf,
            png::ColorType::Rgb => buf.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
            png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 255]).collect(),
            png::ColorType::GrayscaleAlpha => buf.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
            png::ColorType::Indexed => return None,
        };
        return Image::from_rgba(info.width, info.height, rgba);
    }
    if bytes.starts_with(&[0xFF, 0xD8]) {
        let mut dec = jpeg_decoder::Decoder::new(std::io::Cursor::new(bytes));
        let px = dec.decode().ok()?;
        let info = dec.info()?;
        let rgba: Vec<u8> = match info.pixel_format {
            jpeg_decoder::PixelFormat::RGB24 => px.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
            jpeg_decoder::PixelFormat::L8 => px.iter().flat_map(|&g| [g, g, g, 255]).collect(),
            _ => return None,
        };
        return Image::from_rgba(info.width as u32, info.height as u32, rgba);
    }
    None
}

// ---------------------------------------------------------------------------------------------------------
// Fonts

// Static, Latin-only instances of the app's own font (Google Sans Flex, SIL OFL 1.1: see assets/README.md). The
// variable file itself is not used: ttf-parser cannot outline most of its glyphs once gvar is applied.
const SANS_REGULAR: &[u8] = include_bytes!("../../assets/island-Regular.ttf");
const SANS_MEDIUM: &[u8] = include_bytes!("../../assets/island-Medium.ttf");
const SANS_BOLD: &[u8] = include_bytes!("../../assets/island-Bold.ttf");

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Weight {
    Regular,
    Medium,
    Bold,
}

type Glyph = Option<(i32, i32, u32, u32, Vec<u8>)>;

pub struct Fonts {
    faces: Vec<FontRef<'static>>,
    fallback: Vec<FontVec>,
    fallback_tried: bool,
    cache: HashMap<(u8, u16, u16, u8), Glyph>,
}

impl Fonts {
    pub fn new() -> Self {
        let faces = [SANS_REGULAR, SANS_MEDIUM, SANS_BOLD].iter().filter_map(|b| FontRef::try_from_slice(b).ok()).collect();
        Self { faces, fallback: Vec::new(), fallback_tried: false, cache: HashMap::new() }
    }

    fn load_fallbacks(&mut self) {
        self.fallback_tried = true;
        let mut paths: Vec<String> = Vec::new();
        #[cfg(windows)]
        {
            let dir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
            for f in ["segoeui.ttf", "YuGothM.ttc", "msyh.ttc", "malgun.ttf", "seguisym.ttf", "seguiemj.ttf"] {
                paths.push(format!("{dir}\\Fonts\\{f}"));
            }
        }
        #[cfg(not(windows))]
        for f in [
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
        ] {
            paths.push(f.into());
        }
        for p in paths {
            // A big collection is read only when some text needs it.
            if let Ok(bytes) = std::fs::read(&p) {
                if let Ok(f) = FontVec::try_from_vec_and_index(bytes, 0) {
                    self.fallback.push(f);
                }
            }
        }
    }

    /// (face index, glyph id) for a char. Faces 0..=2 are the app font; 3.. are the system fallbacks.
    fn pick(&mut self, ch: char, w: Weight) -> (u8, GlyphId) {
        let base = match w {
            Weight::Regular => 0,
            Weight::Medium => 1,
            Weight::Bold => 2,
        }
        .min(self.faces.len().saturating_sub(1));
        if let Some(f) = self.faces.get(base) {
            let g = f.glyph_id(ch);
            if g.0 != 0 || ch.is_whitespace() {
                return (base as u8, g);
            }
        }
        if !self.fallback_tried {
            self.load_fallbacks();
        }
        for (i, f) in self.fallback.iter().enumerate() {
            let g = f.glyph_id(ch);
            if g.0 != 0 {
                return (3 + i as u8, g);
            }
        }
        (base as u8, GlyphId(0))
    }

    fn advance(&self, face: u8, g: GlyphId, px: f32) -> f32 {
        let s = PxScale::from(px);
        if (face as usize) < 3 {
            self.faces.get(face as usize).map_or(px * 0.5, |f| f.as_scaled(s).h_advance(g))
        } else {
            self.fallback.get(face as usize - 3).map_or(px * 0.5, |f| f.as_scaled(s).h_advance(g))
        }
    }

    fn glyph(&mut self, face: u8, g: GlyphId, px: f32) -> &Glyph {
        let key = (face, g.0, (px * 4.0) as u16, 0);
        if !self.cache.contains_key(&key) {
            let scale = PxScale::from(px);
            let glyph = g.with_scale(scale);
            let outlined = if (face as usize) < 3 {
                self.faces.get(face as usize).and_then(|f| f.outline_glyph(glyph))
            } else {
                self.fallback.get(face as usize - 3).and_then(|f| f.outline_glyph(glyph))
            };
            let bmp = outlined.map(|o| {
                let b = o.px_bounds();
                let (w, h) = ((b.max.x - b.min.x).ceil().max(1.0) as u32, (b.max.y - b.min.y).ceil().max(1.0) as u32);
                let mut cov = vec![0u8; (w * h) as usize];
                o.draw(|x, y, c| {
                    if x < w && y < h {
                        cov[(y * w + x) as usize] = (c.clamp(0.0, 1.0) * 255.0) as u8;
                    }
                });
                (b.min.x.floor() as i32, b.min.y.floor() as i32, w, h, cov)
            });
            if self.cache.len() > 3000 {
                self.cache.clear();
            }
            self.cache.insert(key, bmp);
        }
        &self.cache[&key]
    }

    /// Width of `text` in logical units at this size.
    pub fn measure(&mut self, text: &str, size: f32, w: Weight) -> f32 {
        let mut x = 0.0;
        for ch in text.chars() {
            let (face, g) = self.pick(ch, w);
            x += self.advance(face, g, size);
        }
        x
    }

    /// `text` shortened with "…" so it fits in `max` logical units.
    pub fn fit(&mut self, text: &str, size: f32, w: Weight, max: f32) -> String {
        let text = text.replace(['\n', '\r', '\t'], " ");
        if self.measure(&text, size, w) <= max {
            return text;
        }
        let ell = self.measure("…", size, w);
        let mut out = String::new();
        let mut x = 0.0;
        for ch in text.chars() {
            let (face, g) = self.pick(ch, w);
            let a = self.advance(face, g, size);
            if x + a + ell > max {
                break;
            }
            x += a;
            out.push(ch);
        }
        out.trim_end().to_string() + "…"
    }
}

// ---------------------------------------------------------------------------------------------------------
// Canvas

pub struct Canvas {
    pub pm: Pixmap,
    pub k: f32,
}

impl Canvas {
    pub fn new(w_logical: f32, h_logical: f32, k: f32) -> Self {
        let (w, h) = ((w_logical * k).ceil().max(1.0) as u32, (h_logical * k).ceil().max(1.0) as u32);
        Self { pm: Pixmap::new(w, h).expect("canvas size"), k }
    }

    pub fn width_px(&self) -> u32 {
        self.pm.width()
    }
    pub fn height_px(&self) -> u32 {
        self.pm.height()
    }

    pub fn clear(&mut self) {
        self.pm.fill(Color::TRANSPARENT);
    }

    fn tf(&self) -> Transform {
        Transform::from_scale(self.k, self.k)
    }

    fn paint(c: Color) -> Paint<'static> {
        let mut p = Paint::default();
        p.set_color(c);
        p.anti_alias = true;
        p
    }

    pub fn fill_path(&mut self, path: &Path, c: Color, mask: Option<&Mask>) {
        let tf = self.tf();
        self.pm.fill_path(path, &Self::paint(c), FillRule::Winding, tf, mask);
    }

    pub fn stroke_path(&mut self, path: &Path, c: Color, width: f32, mask: Option<&Mask>) {
        let tf = self.tf();
        let stroke = Stroke { width, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Stroke::default() };
        self.pm.stroke_path(path, &Self::paint(c), &stroke, tf, mask);
    }

    pub fn squircle(&mut self, r: R, radius: f32, c: Color, mask: Option<&Mask>) {
        if r.w < 0.5 || r.h < 0.5 {
            return;
        }
        if let Some(p) = squircle(r, radius, squircle_n(radius, r.h)) {
            self.fill_path(&p, c, mask);
        }
    }

    pub fn circle(&mut self, cx: f32, cy: f32, rad: f32, c: Color, mask: Option<&Mask>) {
        if let Some(p) = PathBuilder::from_circle(cx, cy, rad.max(0.1)) {
            self.fill_path(&p, c, mask);
        }
    }

    /// A mask of this squircle, in pixels, to clip drawing to the island.
    pub fn mask_of(&self, r: R, radius: f32) -> Option<Mask> {
        let mut m = Mask::new(self.pm.width(), self.pm.height())?;
        let p = squircle(r, radius, squircle_n(radius, r.h))?;
        m.fill_path(&p, FillRule::Winding, true, self.tf());
        Some(m)
    }

    /// A mask of any outline (logical units), to clip drawing to it.
    pub fn mask_path(&self, p: &Path) -> Option<Mask> {
        let mut m = Mask::new(self.pm.width(), self.pm.height())?;
        m.fill_path(p, FillRule::Winding, true, self.tf());
        Some(m)
    }

    /// Draws text with its left edge at `x` and its baseline at `y`. Returns the advance.
    pub fn text(&mut self, fonts: &mut Fonts, s: &str, x: f32, y: f32, size: f32, w: Weight, c: Rgb, alpha: f32) -> f32 {
        let px = size * self.k;
        let mut pen = x * self.k;
        let by = (y * self.k).round();
        let (pw, ph) = (self.pm.width() as i32, self.pm.height() as i32);
        let a = alpha.clamp(0.0, 1.0);
        for ch in s.chars() {
            let (face, g) = fonts.pick(ch, w);
            let adv = fonts.advance(face, g, px);
            if g.0 != 0 {
                if let Some((l, t, gw, gh, cov)) = fonts.glyph(face, g, px).as_ref() {
                    let (l, t, gw, gh) = (*l, *t, *gw, *gh);
                    let ox = pen.round() as i32 + l;
                    let oy = by as i32 + t;
                    let data = self.pm.data_mut();
                    for gy in 0..gh as i32 {
                        let yy = oy + gy;
                        if yy < 0 || yy >= ph {
                            continue;
                        }
                        for gx in 0..gw as i32 {
                            let xx = ox + gx;
                            if xx < 0 || xx >= pw {
                                continue;
                            }
                            let cv = cov[(gy as u32 * gw + gx as u32) as usize] as f32 / 255.0 * a;
                            if cv <= 0.003 {
                                continue;
                            }
                            let i = ((yy * pw + xx) * 4) as usize;
                            let inv = 1.0 - cv;
                            for k in 0..3 {
                                data[i + k] = (c[k] as f32 * cv + data[i + k] as f32 * inv).round().min(255.0) as u8;
                            }
                            data[i + 3] = (255.0 * cv + data[i + 3] as f32 * inv).round().min(255.0) as u8;
                        }
                    }
                }
            }
            pen += adv;
        }
        (pen / self.k) - x
    }

    /// Text centred horizontally on `cx`.
    pub fn text_centered(&mut self, fonts: &mut Fonts, s: &str, cx: f32, y: f32, size: f32, w: Weight, c: Rgb, alpha: f32) {
        let width = fonts.measure(s, size, w);
        self.text(fonts, s, cx - width / 2.0, y, size, w, c, alpha);
    }

    /// A picture scaled to fill `r` (cropping the excess), clipped to a squircle of `radius`.
    pub fn image(&mut self, img: &Image, r: R, radius: f32, alpha: f32, mask: Option<&Mask>) {
        let Some(src) = tiny_skia::PixmapRef::from_bytes(&img.data, img.w, img.h) else { return };
        let s = (r.w / img.w as f32).max(r.h / img.h as f32);
        let (dw, dh) = (img.w as f32 * s, img.h as f32 * s);
        let (ox, oy) = (r.x + (r.w - dw) / 2.0, r.y + (r.h - dh) / 2.0);
        let local = Transform::from_scale(s, s).post_translate(ox, oy);
        let mut paint = Paint::default();
        paint.shader = Pattern::new(src, SpreadMode::Pad, FilterQuality::Bilinear, alpha.clamp(0.0, 1.0), local);
        paint.anti_alias = true;
        if let Some(p) = squircle(r, radius, squircle_n(radius, r.h)) {
            let tf = self.tf();
            self.pm.fill_path(&p, &paint, FillRule::Winding, tf, mask);
        }
    }

    /// Draws another canvas's pixels over this one, scaled around `(cx, cy)` (logical) and clipped by `mask`.
    pub fn blit(&mut self, layer: &Pixmap, opacity: f32, scale: f32, cx: f32, cy: f32, mask: Option<&Mask>) {
        let (px, py) = (cx * self.k, cy * self.k);
        let tf = Transform::from_translate(-px, -py).post_scale(scale, scale).post_translate(px, py);
        let paint = PixmapPaint { opacity: opacity.clamp(0.0, 1.0), blend_mode: BlendMode::SourceOver, quality: if (scale - 1.0).abs() < 0.002 { FilterQuality::Nearest } else { FilterQuality::Bilinear } };
        self.pm.draw_pixmap(0, 0, layer.as_ref(), &paint, tf, mask);
    }

    /// Draws another canvas's pixels over this one, moved down by `dy` logical units.
    pub fn blit_shift(&mut self, layer: &Pixmap, opacity: f32, dy: f32, mask: Option<&Mask>) {
        let tf = Transform::from_translate(0.0, dy * self.k);
        let paint = PixmapPaint { opacity: opacity.clamp(0.0, 1.0), blend_mode: BlendMode::SourceOver, quality: FilterQuality::Bilinear };
        self.pm.draw_pixmap(0, 0, layer.as_ref(), &paint, tf, mask);
    }

    /// Gaussian-like blur (three box passes) of the pixels inside `r` (logical), radius in logical units.
    pub fn blur(&mut self, r: R, radius: f32) {
        let rad = (radius * self.k * 0.55).round() as usize;
        if rad == 0 {
            return;
        }
        let (w, h) = (self.pm.width() as usize, self.pm.height() as usize);
        let x0 = ((r.x * self.k).floor().max(0.0) as usize).min(w);
        let y0 = ((r.y * self.k).floor().max(0.0) as usize).min(h);
        let x1 = (((r.right() * self.k).ceil().max(0.0)) as usize).min(w);
        let y1 = (((r.bottom() * self.k).ceil().max(0.0)) as usize).min(h);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        box_blur(self.pm.data_mut(), w, (x0, y0, x1, y1), rad);
    }
}

/// Three separable box passes over the rectangle, with transparent pixels outside it.
fn box_blur(data: &mut [u8], stride: usize, (x0, y0, x1, y1): (usize, usize, usize, usize), rad: usize) {
    let (w, h) = (x1 - x0, y1 - y0);
    let mut line = vec![0u32; w.max(h) * 4];
    let mut out = vec![0u32; w.max(h) * 4];
    for _ in 0..3 {
        for y in y0..y1 {
            for x in 0..w {
                let i = ((y * stride) + x0 + x) * 4;
                for c in 0..4 {
                    line[x * 4 + c] = data[i + c] as u32;
                }
            }
            slide(&line, &mut out, w, rad);
            for x in 0..w {
                let i = ((y * stride) + x0 + x) * 4;
                for c in 0..4 {
                    data[i + c] = out[x * 4 + c] as u8;
                }
            }
        }
        for x in x0..x1 {
            for y in 0..h {
                let i = (((y0 + y) * stride) + x) * 4;
                for c in 0..4 {
                    line[y * 4 + c] = data[i + c] as u32;
                }
            }
            slide(&line, &mut out, h, rad);
            for y in 0..h {
                let i = (((y0 + y) * stride) + x) * 4;
                for c in 0..4 {
                    data[i + c] = out[y * 4 + c] as u8;
                }
            }
        }
    }
}

/// Moving average over `n` pixels (4 channels each) with a window of `2 * rad + 1`.
fn slide(src: &[u32], dst: &mut [u32], n: usize, rad: usize) {
    let win = (2 * rad + 1) as u32;
    let mut acc = [0u32; 4];
    for i in 0..=rad.min(n.saturating_sub(1)) {
        for c in 0..4 {
            acc[c] += src[i * 4 + c];
        }
    }
    for i in 0..n {
        for c in 0..4 {
            dst[i * 4 + c] = acc[c] / win;
        }
        let add = i + rad + 1;
        if add < n {
            for c in 0..4 {
                acc[c] += src[add * 4 + c];
            }
        }
        if i >= rad {
            let sub = i - rad;
            for c in 0..4 {
                acc[c] -= src[sub * 4 + c];
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// Icons, drawn on a 24 × 24 grid

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Icon {
    Play,
    Pause,
    Next,
    Prev,
    Bell,
    Clipboard,
    Phone,
    Sliders,
    Send,
    Check,
    Close,
    Call,
    CallEnd,
    Moon,
    Torch,
    Find,
    Volume,
    Battery,
    Bolt,
    Copy,
    Music,
    File,
    Back,
    Download,
    Home,
    Pin,
    Open,
}

pub fn icon(cv: &mut Canvas, ic: Icon, cx: f32, cy: f32, size: f32, c: Color, mask: Option<&Mask>) {
    let s = size / 24.0;
    let (ox, oy) = (cx - size / 2.0, cy - size / 2.0);
    // Paths are drawn in the 24-grid and mapped into logical space.
    let map = |p: Path| p.transform(Transform::from_scale(s, s).post_translate(ox, oy));
    let fill = |cv: &mut Canvas, p: Option<Path>| {
        if let Some(p) = p.and_then(map) {
            cv.fill_path(&p, c, mask);
        }
    };
    let line = |cv: &mut Canvas, p: Option<Path>, w: f32| {
        if let Some(p) = p.and_then(map) {
            cv.stroke_path(&p, c, w * s, mask);
        }
    };
    let poly = |pts: &[(f32, f32)], close: bool| {
        let mut pb = PathBuilder::new();
        for (i, (x, y)) in pts.iter().enumerate() {
            if i == 0 {
                pb.move_to(*x, *y);
            } else {
                pb.line_to(*x, *y);
            }
        }
        if close {
            pb.close();
        }
        pb.finish()
    };
    let rrect = |x: f32, y: f32, w: f32, h: f32, r: f32| squircle(R::new(x, y, w, h), r, 3.2);
    match ic {
        Icon::Play => fill(cv, poly(&[(7.5, 4.5), (19.5, 12.0), (7.5, 19.5)], true)),
        Icon::Pause => {
            fill(cv, rrect(6.0, 4.5, 4.2, 15.0, 1.4));
            fill(cv, rrect(13.8, 4.5, 4.2, 15.0, 1.4));
        }
        Icon::Next => {
            fill(cv, poly(&[(5.0, 5.0), (15.5, 12.0), (5.0, 19.0)], true));
            fill(cv, rrect(16.2, 5.0, 2.8, 14.0, 1.2));
        }
        Icon::Prev => {
            fill(cv, poly(&[(19.0, 5.0), (8.5, 12.0), (19.0, 19.0)], true));
            fill(cv, rrect(5.0, 5.0, 2.8, 14.0, 1.2));
        }
        Icon::Bell => {
            let mut pb = PathBuilder::new();
            pb.move_to(12.0, 3.0);
            pb.cubic_to(8.2, 3.0, 6.5, 6.0, 6.5, 9.5);
            pb.line_to(6.5, 13.4);
            pb.line_to(4.6, 16.8);
            pb.line_to(19.4, 16.8);
            pb.line_to(17.5, 13.4);
            pb.line_to(17.5, 9.5);
            pb.cubic_to(17.5, 6.0, 15.8, 3.0, 12.0, 3.0);
            pb.close();
            fill(cv, pb.finish());
            fill(cv, PathBuilder::from_circle(12.0, 19.6, 2.1));
        }
        Icon::Clipboard => {
            line(cv, rrect(5.5, 5.0, 13.0, 16.0, 2.4), 1.9);
            fill(cv, rrect(8.5, 2.8, 7.0, 4.6, 1.6));
        }
        Icon::Phone => {
            line(cv, rrect(7.0, 2.8, 10.0, 18.4, 2.6), 1.9);
            line(cv, poly(&[(10.5, 18.0), (13.5, 18.0)], false), 1.8);
        }
        Icon::Sliders => {
            for (y, kx) in [(6.5, 9.0), (12.0, 15.5), (17.5, 8.0)] {
                line(cv, poly(&[(4.0, y), (20.0, y)], false), 1.8);
                fill(cv, PathBuilder::from_circle(kx, y, 2.6));
            }
        }
        Icon::Send => {
            line(cv, poly(&[(12.0, 16.0), (12.0, 4.5)], false), 2.0);
            line(cv, poly(&[(7.5, 9.0), (12.0, 4.5), (16.5, 9.0)], false), 2.0);
            line(cv, poly(&[(5.0, 15.0), (5.0, 19.0), (19.0, 19.0), (19.0, 15.0)], false), 2.0);
        }
        Icon::Download => {
            line(cv, poly(&[(12.0, 4.5), (12.0, 16.0)], false), 2.0);
            line(cv, poly(&[(7.5, 11.5), (12.0, 16.0), (16.5, 11.5)], false), 2.0);
            line(cv, poly(&[(5.0, 15.0), (5.0, 19.0), (19.0, 19.0), (19.0, 15.0)], false), 2.0);
        }
        Icon::Check => line(cv, poly(&[(5.0, 12.5), (10.0, 17.5), (19.0, 7.0)], false), 2.6),
        Icon::Close => {
            line(cv, poly(&[(6.0, 6.0), (18.0, 18.0)], false), 2.4);
            line(cv, poly(&[(18.0, 6.0), (6.0, 18.0)], false), 2.4);
        }
        Icon::Call | Icon::CallEnd => {
            // A handset: a thick arc with a pad at each end. The hang-up one is the same shape turned over.
            let mut pb = PathBuilder::new();
            pb.move_to(6.0, 7.5);
            pb.cubic_to(6.0, 14.5, 9.5, 18.0, 16.5, 18.0);
            let arc = pb.finish();
            let flip = |p: Path| -> Option<Path> {
                if ic == Icon::CallEnd {
                    p.transform(Transform::from_rotate_at(135.0, 12.0, 12.0))
                } else {
                    Some(p)
                }
            };
            let arc = arc.and_then(flip);
            line(cv, arc, 3.6);
            for (px, py) in [(5.2, 5.6), (18.4, 18.8)] {
                let pad = PathBuilder::from_circle(px, py, 2.5).and_then(flip);
                fill(cv, pad);
            }
        }
        Icon::Moon => {
            // A crescent: the outer circle where it lies outside the inner one, then the inner circle where it lies inside.
            let (r1, c1) = (8.6f32, (11.6f32, 12.4f32));
            let (r2, c2) = (7.2f32, (15.6f32, 9.2f32));
            let n = 120usize;
            let on = |c: (f32, f32), r: f32, i: usize| {
                let t = 2.0 * PI * i as f32 / n as f32;
                (c.0 + r * t.cos(), c.1 + r * t.sin())
            };
            let dist = |p: (f32, f32), c: (f32, f32)| ((p.0 - c.0).powi(2) + (p.1 - c.1).powi(2)).sqrt();
            let keep_outer: Vec<bool> = (0..n).map(|i| dist(on(c1, r1, i), c2) >= r2).collect();
            // Start just after a dropped point so the kept ones form one run.
            let start = (0..n).find(|&i| !keep_outer[i]).map_or(0, |i| i + 1);
            let mut pts: Vec<(f32, f32)> = (0..n).map(|k| (start + k) % n).filter(|&i| keep_outer[i]).map(|i| on(c1, r1, i)).collect();
            let mut inner: Vec<(f32, f32)> = (0..n).map(|i| on(c2, r2, i)).filter(|&p| dist(p, c1) <= r1).collect();
            // Order the inner arc so that it continues from where the outer one stopped.
            if let (Some(&last), Some(&first), Some(&end)) = (pts.last(), inner.first(), inner.last()) {
                let _ = first;
                if dist(end, last) < dist(inner[0], last) {
                    inner.reverse();
                }
            }
            // Wrap-around of the inner arc: rotate it to start at its largest gap.
            if inner.len() > 2 {
                let mut gap = 0usize;
                let mut best = 0.0f32;
                for i in 0..inner.len() {
                    let d = dist(inner[i], inner[(i + 1) % inner.len()]);
                    if d > best {
                        best = d;
                        gap = i;
                    }
                }
                let len = inner.len();
                inner.rotate_left((gap + 1) % len);
                if let Some(&last) = pts.last() {
                    if dist(*inner.last().unwrap(), last) < dist(inner[0], last) {
                        inner.reverse();
                    }
                }
            }
            pts.extend(inner);
            fill(cv, poly(&pts, true));
        }
        Icon::Torch => {
            fill(cv, poly(&[(7.4, 2.6), (16.6, 2.6), (15.2, 8.0), (8.8, 8.0)], true));
            fill(cv, rrect(9.0, 9.4, 6.0, 12.0, 1.6));
        }
        Icon::Bolt => fill(cv, poly(&[(13.5, 2.0), (5.5, 13.5), (11.0, 13.5), (10.0, 22.0), (18.5, 9.5), (13.0, 9.5)], true)),
        Icon::Find => {
            line(cv, PathBuilder::from_circle(12.0, 12.0, 8.0), 1.9);
            line(cv, PathBuilder::from_circle(12.0, 12.0, 3.6), 1.9);
            fill(cv, PathBuilder::from_circle(12.0, 12.0, 1.3));
        }
        Icon::Volume => {
            fill(cv, poly(&[(4.0, 9.5), (8.0, 9.5), (13.0, 5.0), (13.0, 19.0), (8.0, 14.5), (4.0, 14.5)], true));
            let mut a = PathBuilder::new();
            a.move_to(16.2, 9.0);
            a.quad_to(18.4, 12.0, 16.2, 15.0);
            line(cv, a.finish(), 1.8);
            let mut b = PathBuilder::new();
            b.move_to(18.8, 6.4);
            b.quad_to(22.6, 12.0, 18.8, 17.6);
            line(cv, b.finish(), 1.8);
        }
        Icon::Battery => {
            line(cv, rrect(2.5, 7.5, 16.0, 9.0, 2.2), 1.7);
            fill(cv, rrect(19.6, 10.4, 2.0, 3.2, 1.0));
        }
        Icon::Copy => {
            line(cv, rrect(8.5, 8.5, 11.5, 11.5, 2.4), 1.9);
            let mut pb = PathBuilder::new();
            pb.move_to(15.5, 8.0);
            pb.line_to(15.5, 6.0);
            pb.quad_to(15.5, 4.0, 13.5, 4.0);
            pb.line_to(6.0, 4.0);
            pb.quad_to(4.0, 4.0, 4.0, 6.0);
            pb.line_to(4.0, 13.5);
            pb.quad_to(4.0, 15.5, 6.0, 15.5);
            pb.line_to(8.0, 15.5);
            line(cv, pb.finish(), 1.9);
        }
        Icon::Music => {
            fill(cv, rrect(10.4, 4.2, 2.2, 13.8, 1.0));
            fill(cv, PathBuilder::from_circle(8.2, 18.2, 3.3));
            fill(cv, poly(&[(12.2, 4.2), (19.0, 6.4), (19.0, 10.6), (12.2, 8.4)], true));
        }
        Icon::File => {
            line(cv, poly(&[(6.5, 3.5), (13.5, 3.5), (18.5, 8.5), (18.5, 20.5), (6.5, 20.5)], true), 1.8);
            line(cv, poly(&[(13.5, 3.5), (13.5, 8.5), (18.5, 8.5)], false), 1.8);
        }
        Icon::Back => line(cv, poly(&[(14.5, 5.5), (8.0, 12.0), (14.5, 18.5)], false), 2.4),
        Icon::Home => {
            line(cv, poly(&[(3.8, 11.6), (12.0, 4.4), (20.2, 11.6)], false), 1.9);
            line(cv, poly(&[(6.4, 10.2), (6.4, 19.6), (17.6, 19.6), (17.6, 10.2)], false), 1.9);
            line(cv, poly(&[(10.2, 19.6), (10.2, 14.4), (13.8, 14.4), (13.8, 19.6)], false), 1.7);
        }
        Icon::Pin => {
            fill(cv, poly(&[(8.6, 3.6), (15.4, 3.6), (14.4, 10.4), (17.6, 13.8), (6.4, 13.8), (9.6, 10.4)], true));
            line(cv, poly(&[(12.0, 13.8), (12.0, 20.6)], false), 1.9);
        }
        Icon::Open => {
            line(cv, poly(&[(10.0, 5.2), (5.2, 5.2), (5.2, 18.8), (18.8, 18.8), (18.8, 14.0)], false), 1.9);
            line(cv, poly(&[(13.6, 4.8), (19.4, 4.8), (19.4, 10.6)], false), 1.9);
            line(cv, poly(&[(19.4, 4.8), (11.0, 13.2)], false), 1.9);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn squircle_stays_inside_its_rectangle() {
        let r = R::new(10.0, 20.0, 100.0, 40.0);
        let p = squircle(r, 20.0, 3.0).unwrap();
        let b = p.bounds();
        assert!((b.left() - 10.0).abs() < 0.01 && (b.right() - 110.0).abs() < 0.01);
        assert!((b.top() - 20.0).abs() < 0.01 && (b.bottom() - 60.0).abs() < 0.01);
    }

    #[test]
    fn blur_spreads_a_dot_and_keeps_the_energy_inside() {
        let mut cv = Canvas::new(40.0, 40.0, 1.0);
        cv.circle(20.0, 20.0, 3.0, Color::WHITE, None);
        let before: u32 = cv.pm.data().chunks_exact(4).map(|p| p[3] as u32).sum();
        cv.blur(R::new(0.0, 0.0, 40.0, 40.0), 8.0);
        let after: u32 = cv.pm.data().chunks_exact(4).map(|p| p[3] as u32).sum();
        let centre = cv.pm.data()[((20 * 40 + 20) * 4 + 3) as usize];
        assert!(centre < 200, "the dot should fade: {centre}");
        assert!((after as f32 - before as f32).abs() / before as f32 > -1.0 && after > before / 2, "{before} {after}");
    }

    #[test]
    fn text_has_ink_and_fits() {
        let mut f = Fonts::new();
        let mut cv = Canvas::new(200.0, 30.0, 2.0);
        let w = cv.text(&mut f, "Alero Island", 4.0, 20.0, 16.0, Weight::Bold, [255, 255, 255], 1.0);
        assert!(w > 60.0 && w < 160.0, "{w}");
        let max = cv.pm.data().chunks_exact(4).map(|p| p[3]).max().unwrap();
        let nz = cv.pm.data().chunks_exact(4).filter(|p| p[3] > 0).count();
        assert!(max > 200, "max alpha {max}, non-zero pixels {nz}, faces {}", f.faces.len());
        let fitted = f.fit("una frase bastante larga para el espacio disponible", 14.0, Weight::Regular, 90.0);
        assert!(fitted.ends_with('…') && f.measure(&fitted, 14.0, Weight::Regular) <= 90.0);
    }

    #[test]
    fn png_covers_decode() {
        let mut out = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut out, 2, 2);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut w = enc.write_header().unwrap();
            w.write_image_data(&[255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128]).unwrap();
        }
        let img = decode_image(&out).unwrap();
        assert_eq!((img.w, img.h), (2, 2));
        assert_eq!(&img.data[0..4], &[255, 0, 0, 255]);
        assert!(decode_image(b"nope").is_none());
    }
}
