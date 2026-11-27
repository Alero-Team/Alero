//! 2D drawing for the island: squircle shapes, text, icons and images, all on the CPU.
//!
//! Everything is expressed in *logical* units; the canvas multiplies them by `k` (display scale × the user's size
//! setting) when it touches pixels. The pixel format is tiny-skia's: premultiplied RGBA8.

use std::collections::HashMap;
use std::f32::consts::{FRAC_PI_2, PI};

use ab_glyph::{Font, FontRef, FontVec, GlyphId, PxScale, ScaleFont};
use tiny_skia::{
    BlendMode, Color, FillRule, FilterQuality, LineCap, LineJoin, Mask, Paint, Path, PathBuilder, Pattern, Pixmap, SpreadMode,
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

/// A notch hanging from the top edge: square top, rounded bottom corners of `radius`, and two concave "ears" of
/// `ear` that melt the top corners into the edge of the screen.
pub fn notch(r: R, radius: f32, ear: f32) -> Option<Path> {
    let radius = radius.min(r.w / 2.0).min(r.h).max(0.0);
    let ear = ear.min(r.h).max(0.0);
    // Quarter circles as cubics (k = 0.5523).
    let k = 0.5523;
    let mut pb = PathBuilder::new();
    pb.move_to(r.x - ear, r.y);
    pb.line_to(r.right() + ear, r.y);
    pb.cubic_to(r.right() + ear * (1.0 - k), r.y, r.right(), r.y + ear * (1.0 - k), r.right(), r.y + ear);
    pb.line_to(r.right(), r.bottom() - radius);
    pb.cubic_to(r.right(), r.bottom() - radius * (1.0 - k), r.right() - radius * (1.0 - k), r.bottom(), r.right() - radius, r.bottom());
    pb.line_to(r.x + radius, r.bottom());
    pb.cubic_to(r.x + radius * (1.0 - k), r.bottom(), r.x, r.bottom() - radius * (1.0 - k), r.x, r.bottom() - radius);
    pb.line_to(r.x, r.y + ear);
    pb.cubic_to(r.x, r.y + ear * (1.0 - k), r.x - ear * (1.0 - k), r.y, r.x - ear, r.y);
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

impl std::fmt::Debug for Image {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Image({}x{})", self.w, self.h)
    }
}

impl Image {
    pub fn from_rgba(w: u32, h: u32, rgba: Vec<u8>) -> Option<Image> {
        if w == 0 || h == 0 || rgba.len() != w as usize * h as usize * 4 {
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
        let mut out = vec![0u8; nw as usize * nh as usize * 4];
        for y in 0..nh {
            for x in 0..nw {
                let mut acc = [0u32; 4];
                for dy in 0..f {
                    for dx in 0..f {
                        let i = ((y * f + dy) as usize * self.w as usize + (x * f + dx) as usize) * 4;
                        for c in 0..4 {
                            acc[c] += self.data[i + c] as u32;
                        }
                    }
                }
                let o = (y as usize * nw as usize + x as usize) * 4;
                for c in 0..4 {
                    out[o + c] = (acc[c] / (f * f)) as u8;
                }
            }
        }
        Image { w: nw, h: nh, data: out }
    }
}

/// Largest picture accepted, in pixels: the header is checked before anything big is allocated.
const MAX_PIXELS: u64 = 4_000_000;

/// PNG or JPEG bytes (a cover, an app icon) to an image.
pub fn decode_image(bytes: &[u8]) -> Option<Image> {
    decode(bytes, None)
}

/// A photo straight from a phone camera (12 to 50 MP) as a preview: JPEG is decoded at 1/2 to 1/8 of its size, which
/// is cheap and stays under MAX_PIXELS; PNG only when it is small enough already.
pub fn thumbnail(bytes: &[u8]) -> Option<Image> {
    decode(bytes, Some(192))
}

fn decode(bytes: &[u8], side: Option<u16>) -> Option<Image> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
        dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut r = dec.read_info().ok()?;
        if r.info().width as u64 * r.info().height as u64 > MAX_PIXELS {
            return None;
        }
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
        // The smallest DCT scale (1/1 .. 1/8) at least `side` big: the full photo is never decoded.
        let (w, h) = match side {
            Some(s) => dec.scale(s, s).ok()?,
            None => {
                dec.read_info().ok()?;
                dec.info().map(|i| (i.width, i.height))?
            }
        };
        if w as u64 * h as u64 > MAX_PIXELS {
            return None;
        }
        let px = dec.decode().ok()?;
        let rgba: Vec<u8> = match dec.info()?.pixel_format {
            jpeg_decoder::PixelFormat::RGB24 => px.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
            jpeg_decoder::PixelFormat::L8 => px.iter().flat_map(|&g| [g, g, g, 255]).collect(),
            _ => return None,
        };
        return Image::from_rgba(w as u32, h as u32, rgba);
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

// Common symbols must not load large CJK collections before reaching the emoji font.
fn fallback_paths() -> Vec<String> {
    let mut paths: Vec<String> = Vec::new();
    #[cfg(windows)]
    {
        let dir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
        for f in ["segoeui.ttf", "seguisym.ttf", "seguiemj.ttf", "YuGothM.ttc", "msyh.ttc", "malgun.ttf"] {
            paths.push(format!("{dir}\\Fonts\\{f}"));
        }
    }
    #[cfg(not(windows))]
    for f in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    ] {
        paths.push(f.into());
    }
    paths
}

type Glyph = Option<(i32, i32, u32, u32, Vec<u8>)>;

pub struct Fonts {
    faces: Vec<FontRef<'static>>,
    fallback: Vec<FontVec>,
    /// System fonts not read yet: each is loaded only when the ones before it lack a glyph.
    pending: Vec<String>,
    cache: HashMap<(u8, u16, u16), Glyph>,
}

impl Fonts {
    pub fn new() -> Self {
        let faces = [SANS_REGULAR, SANS_MEDIUM, SANS_BOLD].iter().filter_map(|b| FontRef::try_from_slice(b).ok()).collect();
        Self { faces, fallback: Vec::new(), pending: fallback_paths(), cache: HashMap::new() }
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
        let mut i = 0;
        loop {
            match self.fallback.get(i) {
                Some(f) => {
                    let g = f.glyph_id(ch);
                    if g.0 != 0 {
                        return (3 + i as u8, g);
                    }
                    i += 1;
                }
                None if self.pending.is_empty() => break,
                None => {
                    // A big collection is read only when some text needs it.
                    let p = self.pending.remove(0);
                    if let Some(f) = std::fs::read(&p).ok().and_then(|b| FontVec::try_from_vec_and_index(b, 0).ok()) {
                        self.fallback.push(f);
                    }
                }
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
        let key = (face, g.0, (px * 4.0) as u16);
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
        let size = size * TEXT_SCALE;
        let mut x = 0.0;
        for ch in text.chars() {
            let (face, g) = self.pick(ch, w);
            x += self.advance(face, g, size);
        }
        x
    }

    /// `text` shortened with "…" so it fits in `max` logical units.
    pub fn fit(&mut self, text: &str, size: f32, w: Weight, max: f32) -> String {
        // Long clipboard or notification texts are cut before measuring: only the start can be shown.
        let text: String = text.chars().take(300).collect::<String>().replace(['\n', '\r', '\t'], " ");
        if self.measure(&text, size, w) <= max {
            return text;
        }
        let ell = self.measure("…", size, w);
        let mut out = String::new();
        let mut x = 0.0;
        for ch in text.chars() {
            let (face, g) = self.pick(ch, w);
            let a = self.advance(face, g, size * TEXT_SCALE);
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

/// Every text of the island, larger than the sizes written in the layout (the user found them hard to read).
pub const TEXT_SCALE: f32 = 1.2;

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

    /// Fills `path` with a vertical gradient: `top` down to `y0`, then towards `bottom` at `y1` (logical units).
    pub fn fill_path_vgradient(&mut self, path: &Path, top: Color, bottom: Color, y0: f32, y1: f32, mask: Option<&Mask>) {
        let stops = vec![tiny_skia::GradientStop::new(0.0, top), tiny_skia::GradientStop::new(1.0, bottom)];
        let Some(shader) = tiny_skia::LinearGradient::new(tiny_skia::Point::from_xy(0.0, y0), tiny_skia::Point::from_xy(0.0, y1.max(y0 + 1.0)), stops, SpreadMode::Pad, Transform::identity()) else {
            return self.fill_path(path, top, mask);
        };
        let mut paint = Paint::default();
        paint.shader = shader;
        paint.anti_alias = true;
        let tf = self.tf();
        self.pm.fill_path(path, &paint, FillRule::Winding, tf, mask);
    }

    /// A circle outline.
    pub fn ring(&mut self, cx: f32, cy: f32, rad: f32, c: Color, width: f32, mask: Option<&Mask>) {
        if let Some(p) = PathBuilder::from_circle(cx, cy, rad.max(0.1)) {
            self.stroke_path(&p, c, width, mask);
        }
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

    /// A mask of any outline, in pixels.
    pub fn mask_path(&self, p: &Path) -> Option<Mask> {
        let mut m = Mask::new(self.pm.width(), self.pm.height())?;
        m.fill_path(p, FillRule::Winding, true, self.tf());
        Some(m)
    }

    pub fn circle(&mut self, cx: f32, cy: f32, rad: f32, c: Color, mask: Option<&Mask>) {
        if let Some(p) = PathBuilder::from_circle(cx, cy, rad.max(0.1)) {
            self.fill_path(&p, c, mask);
        }
    }

    /// Draws text with its left edge at `x` and its baseline at `y`. Returns the advance.
    pub fn text(&mut self, fonts: &mut Fonts, s: &str, x: f32, y: f32, size: f32, w: Weight, c: Rgb, alpha: f32) -> f32 {
        let px = size * TEXT_SCALE * self.k;
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
        // A radius of half the side is a true circle (a contact's photo), not the squircle's rounded square.
        let shape = if radius * 2.0 >= r.w.min(r.h) { PathBuilder::from_circle(r.cx(), r.cy(), r.w.min(r.h) / 2.0) } else { squircle(r, radius, squircle_n(radius, r.h)) };
        if let Some(p) = shape {
            let tf = self.tf();
            self.pm.fill_path(&p, &paint, FillRule::Winding, tf, mask);
        }
    }

    /// Draws another canvas's pixels over this one, scaled around `(cx, cy)` (logical) and clipped by `mask`.
    #[cfg(test)]
    pub fn blit(&mut self, layer: &Pixmap, opacity: f32, scale: f32, cx: f32, cy: f32, mask: Option<&Mask>) {
        let area = R::new(0.0, 0.0, layer.width() as f32 / self.k, layer.height() as f32 / self.k);
        self.blit_area(layer, area, opacity, scale, cx, cy, mask);
    }

    /// Transform only the content bounds, not the transparent remainder of the backing canvas.
    pub fn blit_area(&mut self, layer: &Pixmap, area: R, opacity: f32, scale: f32, cx: f32, cy: f32, mask: Option<&Mask>) {
        let x = (area.x * self.k).max(0.0);
        let y = (area.y * self.k).max(0.0);
        let right = (area.right() * self.k).min(layer.width() as f32);
        let bottom = (area.bottom() * self.k).min(layer.height() as f32);
        let Some(rect) = tiny_skia::Rect::from_xywh(x, y, right - x, bottom - y) else { return };
        let (px, py) = (cx * self.k, cy * self.k);
        let tf = Transform::from_translate(-px, -py).post_scale(scale, scale).post_translate(px, py);
        let paint = Paint {
            shader: Pattern::new(layer.as_ref(), SpreadMode::Pad,
                if (scale - 1.0).abs() < 0.002 { FilterQuality::Nearest } else { FilterQuality::Bilinear },
                opacity.clamp(0.0, 1.0), Transform::identity()),
            blend_mode: BlendMode::SourceOver,
            anti_alias: false,
            ..Paint::default()
        };
        self.pm.fill_rect(rect, &paint, tf, mask);
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
    Wifi,
    Bluetooth,
    Rotate,
    Lock,
    Router,
    Camera,
    CameraSwitch,
    Cast,
    Screenshot,
    Mute,
    ClipSend,
    Lyrics,
    Reply,
    SpeakerLow,
    MailRead,
    MicOff,
}

/// Draws `ic` from Fluent UI System Icons (the app's icon set): regular (outline), except media keys, call buttons and the
/// charging bolt, which are filled as in the app.
pub fn icon(cv: &mut Canvas, ic: Icon, cx: f32, cy: f32, size: f32, c: Color, mask: Option<&Mask>) {
    let filled = matches!(ic, Icon::Play | Icon::Pause | Icon::Next | Icon::Prev | Icon::Bolt | Icon::Call | Icon::CallEnd);
    draw_icon(cv, ic, filled, cx, cy, size, c, mask);
}

/// The filled twin, for a control that is on (the app fills the icon of a selected tile the same way).
pub fn icon_filled(cv: &mut Canvas, ic: Icon, cx: f32, cy: f32, size: f32, c: Color, mask: Option<&Mask>) {
    draw_icon(cv, ic, true, cx, cy, size, c, mask);
}

#[allow(clippy::too_many_arguments)]
fn draw_icon(cv: &mut Canvas, ic: Icon, filled: bool, cx: f32, cy: f32, size: f32, c: Color, mask: Option<&Mask>) {
    let ops = glyph(ic, filled);
    let mut pb = PathBuilder::new();
    let mut i = 0;
    while i < ops.len() {
        let a = |k: usize| ops.get(i + k).copied().unwrap_or(0.0);
        i += match ops[i] as u8 {
            0 => { pb.move_to(a(1), a(2)); 3 }
            1 => { pb.line_to(a(1), a(2)); 3 }
            2 => { pb.quad_to(a(1), a(2), a(3), a(4)); 5 }
            3 => { pb.cubic_to(a(1), a(2), a(3), a(4), a(5), a(6)); 7 }
            _ => { pb.close(); 1 }
        };
    }
    let s = size / 24.0;
    if let Some(p) = pb.finish().and_then(|p| p.transform(Transform::from_scale(s, s).post_translate(cx - size / 2.0, cy - size / 2.0))) {
        cv.fill_path(&p, c, mask);
    }
}

fn glyph(ic: Icon, filled: bool) -> &'static [f32] {
    use super::fluent::*;
    let (r, f) = match ic {
        Icon::Play => (PLAY_REGULAR, PLAY_FILLED),
        Icon::Pause => (PAUSE_REGULAR, PAUSE_FILLED),
        Icon::Next => (NEXT_REGULAR, NEXT_FILLED),
        Icon::Prev => (PREV_REGULAR, PREV_FILLED),
        Icon::Bell => (BELL_REGULAR, BELL_FILLED),
        Icon::Clipboard => (CLIPBOARD_REGULAR, CLIPBOARD_FILLED),
        Icon::Phone => (PHONE_REGULAR, PHONE_FILLED),
        Icon::Sliders => (SLIDERS_REGULAR, SLIDERS_FILLED),
        Icon::Send => (SEND_REGULAR, SEND_FILLED),
        Icon::Download => (DOWNLOAD_REGULAR, DOWNLOAD_FILLED),
        Icon::Check => (CHECK_REGULAR, CHECK_FILLED),
        Icon::Close => (CLOSE_REGULAR, CLOSE_FILLED),
        Icon::Call => (CALL_REGULAR, CALL_FILLED),
        Icon::CallEnd => (CALL_END_REGULAR, CALL_END_FILLED),
        Icon::Moon => (MOON_REGULAR, MOON_FILLED),
        Icon::Torch => (TORCH_REGULAR, TORCH_FILLED),
        Icon::Find => (FIND_REGULAR, FIND_FILLED),
        Icon::Volume => (VOLUME_REGULAR, VOLUME_FILLED),
        Icon::Battery => (BATTERY_REGULAR, BATTERY_FILLED),
        Icon::Bolt => (BOLT_REGULAR, BOLT_FILLED),
        Icon::Copy => (COPY_REGULAR, COPY_FILLED),
        Icon::Music => (MUSIC_REGULAR, MUSIC_FILLED),
        Icon::File => (FILE_REGULAR, FILE_FILLED),
        Icon::Back => (BACK_REGULAR, BACK_FILLED),
        Icon::Wifi => (WIFI_REGULAR, WIFI_FILLED),
        Icon::Bluetooth => (BLUETOOTH_REGULAR, BLUETOOTH_FILLED),
        Icon::Rotate => (ROTATE_REGULAR, ROTATE_FILLED),
        Icon::Lock => (LOCK_REGULAR, LOCK_FILLED),
        Icon::Router => (ROUTER_REGULAR, ROUTER_FILLED),
        Icon::Camera => (CAMERA_REGULAR, CAMERA_FILLED),
        Icon::CameraSwitch => (CAMERA_SWITCH_REGULAR, CAMERA_SWITCH_FILLED),
        Icon::Cast => (CAST_REGULAR, CAST_FILLED),
        Icon::Screenshot => (SCREENSHOT_REGULAR, SCREENSHOT_FILLED),
        Icon::Mute => (MUTE_REGULAR, MUTE_FILLED),
        Icon::ClipSend => (CLIP_SEND_REGULAR, CLIP_SEND_FILLED),
        Icon::Lyrics => (LYRICS_REGULAR, LYRICS_FILLED),
        Icon::Reply => (REPLY_REGULAR, REPLY_FILLED),
        Icon::SpeakerLow => (SPEAKER_LOW_REGULAR, SPEAKER_LOW_FILLED),
        Icon::MailRead => (MAIL_READ_REGULAR, MAIL_READ_FILLED),
        Icon::MicOff => (MIC_OFF_REGULAR, MIC_OFF_FILLED),
    };
    if filled { f } else { r }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_camera_photo_too_big_to_decode_still_gives_a_small_preview() {
        let (w, h) = (2400u16, 2000u16);
        let rgb: Vec<u8> = (0..w as usize * h as usize).flat_map(|i| [(i % 251) as u8, 90, 160]).collect();
        let mut jpg = Vec::new();
        jpeg_encoder::Encoder::new(&mut jpg, 80).encode(&rgb, w, h, jpeg_encoder::ColorType::Rgb).unwrap();
        assert!(decode_image(&jpg).is_none(), "4.8 MP is over MAX_PIXELS");
        let t = thumbnail(&jpg).expect("preview");
        assert_eq!((t.w, t.h), (300, 250), "1/8 is enough for the island's 192 px");
    }

    #[test]
    fn bounded_composition_matches_the_full_canvas_at_every_scale() {
        for k in [1.0, 1.25, 2.0] {
            let area = R::new(60.0, 0.0, 180.0, 130.0);
            let mut layer = Canvas::new(300.0, 180.0, k);
            layer.squircle(area.inset(8.0, 8.0, 8.0, 8.0), 12.0, color([200, 80, 40], 0.7), None);
            layer.circle(area.cx(), 55.0, 30.0, Color::WHITE, None);
            for scale in [0.90, 0.97, 1.0, 1.04] {
                for opacity in [0.2, 1.0] {
                    let mut actual = Canvas::new(300.0, 180.0, k);
                    let mut expected = Canvas::new(300.0, 180.0, k);
                    let mask = actual.mask_path(&notch(area, 24.0, 10.0).unwrap()).unwrap();
                    actual.blit_area(&layer.pm, area.inflate(2.0), opacity, scale, area.cx(), area.cy(), Some(&mask));
                    let (px, py) = (area.cx() * k, area.cy() * k);
                    let tf = Transform::from_translate(-px, -py).post_scale(scale, scale).post_translate(px, py);
                    let paint = tiny_skia::PixmapPaint { opacity, quality: if (scale - 1.0).abs() < 0.002 { FilterQuality::Nearest } else { FilterQuality::Bilinear }, ..Default::default() };
                    expected.pm.draw_pixmap(0, 0, layer.pm.as_ref(), &paint, tf, Some(&mask));
                    assert_eq!(actual.pm.data(), expected.pm.data(), "k={k} scale={scale} opacity={opacity}");
                }
            }
        }
    }

    #[test]
    fn squircle_stays_inside_its_rectangle() {
        let r = R::new(10.0, 20.0, 100.0, 40.0);
        let p = squircle(r, 20.0, 3.0).unwrap();
        let b = p.bounds();
        assert!((b.left() - 10.0).abs() < 0.01 && (b.right() - 110.0).abs() < 0.01);
        assert!((b.top() - 20.0).abs() < 0.01 && (b.bottom() - 60.0).abs() < 0.01);
    }

    #[cfg(windows)]
    #[test]
    fn common_symbols_do_not_load_large_language_collections() {
        let mut fonts = Fonts::new();
        let (_, glyph) = fonts.pick('🎧', Weight::Regular);
        assert_ne!(glyph.0, 0, "the emoji remains supported");
        assert!(fonts.pending.iter().any(|p| p.ends_with("YuGothM.ttc")), "unrelated CJK collections must remain unloaded");
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

    #[test]
    fn huge_pictures_are_refused_from_the_header() {
        let mut out = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut out, 60_000, 60_000);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().unwrap();
        }
        assert!(decode_image(&out).is_none());
    }
}
