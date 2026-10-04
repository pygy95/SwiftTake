import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A portable, offline viewer. Swift writes a single document containing its
/// image and browser code; no server, third-party library or network is needed.
nonisolated enum InteractivePanoramaWriter {
    enum WriteError: LocalizedError {
        case invalidGeometry, encodingFailed
        var errorDescription: String? {
            switch self {
            case .invalidGeometry: "The interactive panorama has invalid dimensions or coverage."
            case .encodingFailed: "The interactive panorama image could not be encoded."
            }
        }
    }

    static func write(panorama: CGImage, sweepDegrees: Double, to url: URL, alignmentNote: String? = nil) throws {
        let document = try document(panorama: panorama, sweepDegrees: sweepDegrees, alignmentNote: alignmentNote)
        try Task.checkCancellation()
        try document.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Shared renderer for the exported document and the app's in-memory preview.
    static func document(panorama: CGImage, sweepDegrees: Double, embedded: Bool = false,
                          alignmentNote: String? = nil) throws -> String {
        try Task.checkCancellation()
        guard panorama.width > 1, panorama.height > 1,
              sweepDegrees.isFinite, sweepDegrees > 1, sweepDegrees <= 360 else {
            throw WriteError.invalidGeometry
        }
        // Keep the original full-resolution PNG separately. Bound the browser
        // texture and convert HDR to a portable SDR image before embedding it.
        let scale = min(1, 8192.0 / Double(max(panorama.width, panorama.height)))
        let width = max(2, Int(Double(panorama.width) * scale))
        let height = max(2, Int(Double(panorama.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WriteError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(panorama, in: CGRect(x: 0, y: 0, width: width, height: height))
        let png = NSMutableData()
        guard let image = context.makeImage(),
              let encoder = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.encodingFailed
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw WriteError.encodingFailed }
        try Task.checkCancellation()
        let note = (alignmentNote ?? "").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return template
            .replacingOccurrences(of: "__ALIGNMENT_NOTE__", with: note.isEmpty ? "" : "<p class=\"alignment-note\">\(note)</p>")
            .replacingOccurrences(of: "__EMBEDDED_STYLE__", with: embedded ? embeddedStyle : "")
            .replacingOccurrences(of: "__EXPLORE_HINT__", with: embedded
                ? "Scroll to explore · Pinch to zoom"
                : "Drag or scroll sideways to explore · Pinch or scroll vertically to zoom")
            .replacingOccurrences(of: "__SWEEP__", with: String(sweepDegrees * .pi / 180))
            .replacingOccurrences(of: "__ASPECT__", with: String(Double(panorama.width) / Double(panorama.height)))
            .replacingOccurrences(of: "__IMAGE__", with: (png as Data).base64EncodedString())
    }

    // The app supplies native controls; exported HTML retains its own toolbar.
    private static let embeddedStyle = """
    html, body, main { width:100%; height:100%; min-height:0; margin:0; padding:0; max-width:none; overflow:hidden }
    header, .alignment-note, .controls { display:none!important }
    #stage { width:100%; height:100%; min-height:0; border-radius:0; box-shadow:none }
    #status { position:absolute; width:1px; height:1px; overflow:hidden; clip-path:inset(50%); margin:0 }
    #status.viewer-error { bottom:12px; left:12px; right:12px; width:auto; height:auto; padding:8px 12px; clip-path:none; background:#1c1c1e; color:#f5f5f7; border-radius:6px }
    """

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; base-uri 'none'; form-action 'none'">
    <title>Panorama — SwiftTake</title>
    <style>
      :root { color-scheme:dark; font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#101012; color:#f5f5f7; -webkit-font-smoothing:antialiased }
      * { box-sizing:border-box } body { margin:0 } main { display:flex; flex-direction:column; max-width:1800px; height:100vh; height:100svh; min-height:240px; margin:auto; padding:20px 24px 12px }
      header { display:flex; flex:none; justify-content:space-between; align-items:center; gap:16px; padding:0 2px; margin-bottom:16px }
      .identity { display:flex; align-items:center; gap:12px } .brand { font-weight:500; letter-spacing:-.2px; color:#aaaab0 }
      .divider { width:1px; height:16px; background:#ffffff24 } h1 { font-size:17px; font-weight:600; letter-spacing:-.4px; margin:0 }
      .alignment-note { flex:none; color:#aaaab0; font-size:12px; line-height:1.5; margin:0 2px 12px }
      #coverage { color:#aaaab0; margin:0; font-size:12px; font-weight:500; white-space:nowrap }
      #stage { display:flex; flex-direction:column; flex:1; min-height:120px; overflow:hidden; border-radius:12px; background:#080809; box-shadow:0 0 0 1px #ffffff12; isolation:isolate }
      #viewport { position:relative; flex:1; min-height:0; overflow:hidden }
      canvas { width:100%; height:100%; display:block; touch-action:none; cursor:grab }
      canvas.dragging { cursor:grabbing } #flat { width:100%; height:100%; object-fit:contain; display:block }
      [hidden] { display:none!important } #stage:fullscreen { width:100%; height:100%; border-radius:0 }
      .controls { display:flex; flex:none; justify-content:center; align-items:center; gap:6px; padding:5px 10px max(5px,env(safe-area-inset-bottom)); background:#1c1c1e; border-top:1px solid #ffffff12 }
      button { appearance:none; flex-shrink:0; font:inherit; font-size:12px; font-weight:500; color:inherit; background:transparent; border:0; border-radius:6px; height:30px; padding:0 10px; cursor:pointer; transition:background .15s }
      button:hover { background:#ffffff16 } button:active { background:#ffffff26 } button:disabled { opacity:.35; cursor:default }
      button[aria-pressed=true] { background:#ffffff22 } .icon-button { width:30px; padding:7px; display:grid; place-items:center }
      svg { display:block; width:16px; height:16px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round }
      :focus-visible { outline:3px solid #64b5ff; outline-offset:2px } canvas:focus-visible { outline-offset:-4px }
      .zoom-control { display:flex; align-items:center; gap:7px; padding:0 10px; border-left:1px solid #ffffff20; border-right:1px solid #ffffff20; height:20px }
      input { accent-color:#f5f5f7; width:84px; min-height:30px; margin:0; cursor:pointer } .zoom-mark { color:#b8b8bf; font-size:14px; user-select:none }
      #status { flex:none; text-align:center; color:#9999a1; font-size:11px; margin:10px 0 0; min-height:1.4em }
      .sr-only { position:absolute; width:1px; height:1px; padding:0; margin:-1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0 }
      @media(max-width:600px) { main { padding:14px 12px 10px } header { margin-bottom:12px } .identity { gap:10px } .brand { font-size:13px } h1 { font-size:16px } .controls { gap:2px; padding-left:4px; padding-right:4px } input { width:68px } .zoom-control { gap:5px; padding:0 7px } }
      @media(pointer:coarse) { button { height:44px; min-width:44px } input { min-height:44px } }
      @media(prefers-reduced-motion:reduce) { button { transition:none } }
      @media(prefers-reduced-transparency:reduce) { .controls { background:#242426; backdrop-filter:none; -webkit-backdrop-filter:none } }
      @media(forced-colors:active) { button,.controls { border:1px solid ButtonText } }
      __EMBEDDED_STYLE__
    </style>
    <main>
      <header><div class="identity"><span class="brand">SwiftTake</span><span class="divider" aria-hidden="true"></span><h1>Panorama</h1></div><p id="coverage" hidden>360°</p></header>
      __ALIGNMENT_NOTE__
      <div id="stage">
        <div id="viewport">
        <img id="flat" src="data:image/png;base64,__IMAGE__" alt="The complete stitched panorama">
        <canvas id="view" tabindex="0" role="img" aria-label="Interactive panorama. Drag or use arrow keys to look around. Pinch or use plus and minus to zoom; Home resets the view." hidden></canvas>
        </div>
        <div class="controls" role="group" aria-label="Panorama controls">
          <button id="reset" class="icon-button" title="Reset view" aria-label="Reset view" disabled><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 10a8 8 0 1 1 1 7M4 4v6h6"/></svg></button>
          <label class="zoom-control"><span class="sr-only">Zoom</span><span class="zoom-mark" aria-hidden="true">−</span><input id="zoom" aria-label="Zoom" type="range" min="1" max="4" step=".05" value="1" disabled><span class="zoom-mark" aria-hidden="true">+</span></label>
          <button id="flatToggle" aria-pressed="false" title="View the complete panorama" disabled>Overview</button>
          <button id="fullscreen" class="icon-button" title="Enter full screen" aria-label="Enter full screen" hidden><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5"/></svg></button>
        </div>
      </div>
      <p id="status" role="status">Loading interactive view…</p>
      <noscript><p>JavaScript is disabled. The full panorama is shown above.</p></noscript>
    </main>
    <script>
    (() => {
      'use strict';
      const sweep = __SWEEP__, imageAspect = __ASPECT__, fullCircle = Math.abs(sweep - Math.PI * 2) < 1e-6;
      const exploreHint = '__EXPLORE_HINT__';
      document.getElementById('coverage').hidden=!fullCircle;
      const canvas = document.getElementById('view'), flat = document.getElementById('flat');
      const stage = document.getElementById('stage'), status = document.getElementById('status');
      const viewport = document.getElementById('viewport');
      const zoom = document.getElementById('zoom'), reset = document.getElementById('reset');
      const toggle = document.getElementById('flatToggle'), fullscreen = document.getElementById('fullscreen');
      let yaw = 0, pitch = 0, hfov = 1, aspect = 1, flatMode = false, drag = null;
      const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
      function fallback(message) {
        status.classList.add('viewer-error');
        window.webkit?.messageHandlers?.panoramaState?.postMessage({zoom:1,available:false});
        canvas.hidden = true; flat.hidden = false;
        reset.disabled = zoom.disabled = toggle.disabled = true;
        status.textContent = message + ' The full image is shown instead.';
      }
      function start() {
        if (!flat.naturalWidth) { fallback('The embedded image could not be read.'); return; }
        const gl = canvas.getContext('webgl2', { alpha:false, antialias:false, depth:false, preserveDrawingBuffer:true });
        if (!gl) { fallback('Interactive graphics are unavailable in this browser.'); return; }
        try {
          const shader = (kind, source) => {
            const s = gl.createShader(kind); gl.shaderSource(s, source); gl.compileShader(s);
            if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error('Shader compilation failed');
            return s;
          };
          const vertex = shader(gl.VERTEX_SHADER, `#version 300 es
            void main() {
              vec2 p = gl_VertexID == 0 ? vec2(-1.,-1.) : (gl_VertexID == 1 ? vec2(3.,-1.) : vec2(-1.,3.));
              gl_Position = vec4(p,0.,1.);
            }`);
          const fragment = shader(gl.FRAGMENT_SHADER, `#version 300 es
            precision highp float;
            uniform sampler2D panorama;
            uniform vec2 resolution;
            uniform float yaw, pitch, hfov, sweep, verticalScale;
            uniform bool fullCircle;
            out vec4 color;
            void main() {
              vec2 p = 2. * gl_FragCoord.xy / resolution - 1.;
              float t = tan(hfov * .5);
              vec3 r = vec3(p.x*t, p.y*t*resolution.y/resolution.x, 1.);
              r.yz = vec2(cos(pitch)*r.y + sin(pitch)*r.z, -sin(pitch)*r.y + cos(pitch)*r.z);
              r.xz = vec2(cos(yaw)*r.x + sin(yaw)*r.z, -sin(yaw)*r.x + cos(yaw)*r.z);
              float u = atan(r.x,r.z)/sweep + .5;
              float v = .5 - r.y / (length(r.xz)*verticalScale);
              if (fullCircle) u = fract(u);
              if ((!fullCircle && (u<0. || u>1.)) || v<0. || v>1.) { color=vec4(.03,.03,.035,1.); return; }
              color = vec4(texture(panorama,vec2(u,v)).rgb,1.);
            }`);
          const program = gl.createProgram(); gl.attachShader(program,vertex); gl.attachShader(program,fragment); gl.linkProgram(program);
          if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error('Shader linking failed');
          gl.useProgram(program); gl.deleteShader(vertex); gl.deleteShader(fragment);
          let textureImage = flat;
          const maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);
          if (Math.max(flat.naturalWidth,flat.naturalHeight) > maxTexture) {
            textureImage = document.createElement('canvas');
            const scale = maxTexture/Math.max(flat.naturalWidth,flat.naturalHeight);
            textureImage.width = Math.max(1,Math.floor(flat.naturalWidth*scale));
            textureImage.height = Math.max(1,Math.floor(flat.naturalHeight*scale));
            textureImage.getContext('2d').drawImage(flat,0,0,textureImage.width,textureImage.height);
          }
          gl.bindTexture(gl.TEXTURE_2D,gl.createTexture());
          gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,fullCircle?gl.REPEAT:gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
          gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,textureImage);
          if (gl.getError() !== gl.NO_ERROR) throw new Error('Texture upload failed');
          const loc = Object.fromEntries(['resolution','yaw','pitch','hfov','sweep','verticalScale','fullCircle'].map(n=>[n,gl.getUniformLocation(program,n)]));
          const verticalScale = sweep/imageAspect, verticalHalfAngle = Math.atan(verticalScale/2);
          let reportedZoom = null;
          function draw() {
            if (flatMode || gl.isContextLost()) return;
            const w=Math.max(1,viewport.clientWidth), h=Math.max(1,viewport.clientHeight);
            aspect=w/h;
            const dpr=Math.min(window.devicePixelRatio||1,2,gl.getParameter(gl.MAX_RENDERBUFFER_SIZE)/Math.max(w,h));
            const bw=Math.max(1,Math.round(w*dpr)), bh=Math.max(1,Math.round(h*dpr));
            if (canvas.width!==bw || canvas.height!==bh) { canvas.width=bw; canvas.height=bh; }
            const base=Math.min(100*Math.PI/180,sweep,2*Math.atan(aspect*verticalScale/2));
            hfov=2*Math.atan(Math.tan(base/2)/Number(zoom.value));
            if (fullCircle) yaw=Math.atan2(Math.sin(yaw),Math.cos(yaw));
            else yaw=clamp(yaw,-Math.max(0,(sweep-hfov)/2),Math.max(0,(sweep-hfov)/2));
            const pitchLimit=Math.max(0,verticalHalfAngle-Math.atan(Math.tan(hfov/2)/aspect));
            pitch=clamp(pitch,-pitchLimit,pitchLimit);
            gl.viewport(0,0,bw,bh); gl.uniform2f(loc.resolution,bw,bh);
            gl.uniform1f(loc.yaw,yaw); gl.uniform1f(loc.pitch,pitch); gl.uniform1f(loc.hfov,hfov);
            gl.uniform1f(loc.sweep,sweep); gl.uniform1f(loc.verticalScale,verticalScale); gl.uniform1i(loc.fullCircle,fullCircle?1:0);
            gl.drawArrays(gl.TRIANGLES,0,3);
            gl.flush();
            const currentZoom = Number(zoom.value);
            if (reportedZoom !== currentZoom) {
              reportedZoom = currentZoom;
              window.webkit?.messageHandlers?.panoramaState?.postMessage({zoom:currentZoom,available:true});
            }
          }
          // Direct input and initial display draw immediately, even when
          // embedded WebKit suspends animation callbacks in inactive windows.
          function schedule() { draw(); }
          const arrowKeys=new Set(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown']), heldKeys=new Set();
          const reducedMotion=window.matchMedia('(prefers-reduced-motion: reduce)');
          let keyFrame=null, keyTime=0, pendingYaw=0, pendingPitch=0;
          function stopKeys() {
            heldKeys.clear(); pendingYaw=pendingPitch=0;
            if (keyFrame!==null) cancelAnimationFrame(keyFrame);
            keyFrame=null;
          }
          function animateKeys(now) {
            keyFrame=null;
            if (document.hidden || flatMode || gl.isContextLost()) { stopKeys(); return; }
            // Cap delayed frames: returning from a stalled/hidden window must
            // never jump across the scene. Movement does not use OS key repeat.
            const dt=clamp((now-keyTime)/1000,0,.05); keyTime=now;
            const horizontal=Number(heldKeys.has('ArrowRight'))-Number(heldKeys.has('ArrowLeft'));
            const vertical=Number(heldKeys.has('ArrowUp'))-Number(heldKeys.has('ArrowDown'));
            const distance=hfov*.65*dt/Math.max(1,Math.hypot(horizontal,vertical));
            pendingYaw+=horizontal*distance; pendingPitch+=vertical*distance;
            const blend=reducedMotion.matches?1:1-Math.exp(-dt/.045);
            const dx=pendingYaw*blend, dy=pendingPitch*blend;
            yaw+=dx; pitch+=dy; pendingYaw-=dx; pendingPitch-=dy;
            draw();
            if (heldKeys.size || Math.hypot(pendingYaw,pendingPitch)>hfov*.0001) {
              keyFrame=requestAnimationFrame(animateKeys);
            } else { pendingYaw=pendingPitch=0; }
          }
          function startKeys(key) {
            if (heldKeys.has(key)) return;
            heldKeys.add(key);
            // A brief tap still moves a small, predictable distance.
            const tap=hfov*.025;
            if (key==='ArrowLeft') pendingYaw-=tap;
            if (key==='ArrowRight') pendingYaw+=tap;
            if (key==='ArrowUp') pendingPitch+=tap;
            if (key==='ArrowDown') pendingPitch-=tap;
            if (keyFrame===null) { keyTime=performance.now(); keyFrame=requestAnimationFrame(animateKeys); }
          }
          window.addEventListener('keyup',e=>{ heldKeys.delete(e.key); });
          window.addEventListener('blur',stopKeys);
          window.addEventListener('pagehide',stopKeys);
          canvas.addEventListener('blur',stopKeys);
          document.addEventListener('visibilitychange',()=>{ if (document.hidden) stopKeys(); });
          function setZoom(value) {
            if (!Number.isFinite(value)) return;
            stopKeys(); zoom.value=String(clamp(value,1,4)); schedule();
          }
          const touches=new Map();
          let pinch=null, gestureZoom=null;
          function touchDistance() {
            const [a,b]=[...touches.values()];
            return Math.hypot(a.x-b.x,a.y-b.y);
          }
          function stopPointers() {
            touches.clear(); pinch=null; gestureZoom=null; drag=null;
            canvas.classList.remove('dragging');
          }
          canvas.addEventListener('blur',stopPointers);
          window.addEventListener('blur',stopPointers);
          window.addEventListener('pagehide',stopPointers);
          document.addEventListener('visibilitychange',()=>{ if (document.hidden) stopPointers(); });
          canvas.addEventListener('pointerdown',e=>{
            if (flatMode || e.button!==0) return;
            stopKeys(); canvas.focus();
            if (e.pointerType==='touch') {
              touches.set(e.pointerId,{x:e.clientX,y:e.clientY});
              canvas.setPointerCapture(e.pointerId);
              if (touches.size>=2) {
                pinch={distance:Math.max(1,touchDistance()),zoom:Number(zoom.value)};
                gestureZoom=null; drag=null; canvas.classList.remove('dragging'); return;
              }
            }
            if (drag) return;
            drag={id:e.pointerId,x:e.clientX,y:e.clientY}; canvas.setPointerCapture(e.pointerId); canvas.classList.add('dragging');
          });
          canvas.addEventListener('pointermove',e=>{
            if (touches.has(e.pointerId)) touches.set(e.pointerId,{x:e.clientX,y:e.clientY});
            if (pinch && touches.size>=2) {
              setZoom(pinch.zoom*touchDistance()/pinch.distance); return;
            }
            if (gestureZoom!==null || !drag || drag.id!==e.pointerId) return;
            yaw-=(e.clientX-drag.x)/Math.max(1,canvas.clientWidth)*hfov;
            pitch+=(e.clientY-drag.y)/Math.max(1,canvas.clientHeight)*2*Math.atan(Math.tan(hfov/2)/aspect);
            drag.x=e.clientX; drag.y=e.clientY; schedule();
          });
          function endPointer(e) {
            const removed=touches.delete(e.pointerId);
            if (!removed && drag?.id!==e.pointerId) return;
            drag=null; pinch=null; canvas.classList.remove('dragging');
            if (touches.size>=2) {
              pinch={distance:Math.max(1,touchDistance()),zoom:Number(zoom.value)};
            } else if (touches.size===1) {
              const [id,point]=[...touches.entries()][0];
              drag={id,x:point.x,y:point.y}; canvas.classList.add('dragging');
            }
          }
          canvas.addEventListener('pointerup',endPointer);
          canvas.addEventListener('lostpointercapture',endPointer);
          canvas.addEventListener('pointercancel',stopPointers);
          // Safari and embedded WebKit use GestureEvent for trackpad pinches.
          // Touch pointers own touch-screen pinches, avoiding duplicate scaling.
          canvas.addEventListener('gesturestart',e=>{
            e.preventDefault();
            if (flatMode || pinch) return;
            stopKeys(); drag=null; canvas.classList.remove('dragging');
            gestureZoom=Number(zoom.value);
          },{passive:false});
          canvas.addEventListener('gesturechange',e=>{
            e.preventDefault();
            if (gestureZoom!==null && !pinch && e.scale>0) setZoom(gestureZoom*e.scale);
          },{passive:false});
          canvas.addEventListener('gestureend',e=>{ e.preventDefault(); gestureZoom=null; },{passive:false});
          canvas.addEventListener('wheel',e=>{
            e.preventDefault();
            if (flatMode || pinch || gestureZoom!==null) return;
            const dx=e.deltaX*(e.deltaMode===1?16:(e.deltaMode===2?canvas.clientWidth:1));
            const dy=e.deltaY*(e.deltaMode===1?16:(e.deltaMode===2?canvas.clientHeight:1));
            // Follow the trackpad's native momentum and scroll direction.
            // Ignore vertical drift during a horizontal swipe; pinch-to-zoom
            // wheel events retain zoom even when they include sideways drift.
            if (!e.ctrlKey && Math.abs(dx)>Math.abs(dy)) {
              stopKeys();
              yaw+=dx/Math.max(1,canvas.clientWidth)*hfov;
              schedule();
            } else if (dy!==0) {
              setZoom(Number(zoom.value)*Math.exp(clamp(-dy*.001,-.5,.5)));
            }
          },{passive:false});
          canvas.addEventListener('keydown',e=>{
            if (e.metaKey || e.ctrlKey || e.altKey || flatMode) return;
            if (arrowKeys.has(e.key)) {
              e.preventDefault();
              if (!e.repeat) startKeys(e.key);
              return;
            }
            switch(e.key) {
              case '+': case '=': setZoom(Number(zoom.value)*1.2); break;
              case '-': setZoom(Number(zoom.value)/1.2); break;
              case 'Home': stopKeys(); stopPointers(); yaw=pitch=0; zoom.value='1'; break;
              default:return;
            }
            e.preventDefault(); schedule();
          });
          zoom.addEventListener('input',()=>{ stopKeys(); stopPointers(); schedule(); });
          function resetView() { stopKeys(); stopPointers(); yaw=pitch=0; zoom.value='1'; schedule(); }
          reset.addEventListener('click',resetView);
          window.swiftTakePanorama = {setZoom, reset:resetView};
          toggle.addEventListener('click',()=>{
            stopKeys(); stopPointers();
            flatMode=!flatMode; canvas.hidden=flatMode; flat.hidden=!flatMode;
            reset.disabled=zoom.disabled=flatMode; toggle.setAttribute('aria-pressed',String(flatMode));
            toggle.textContent=flatMode?'Explore':'Overview';
            toggle.title=flatMode?'Return to the interactive view':'View the complete panorama';
            status.textContent=flatMode?'The complete panorama · Choose Explore to look around':exploreHint;
            schedule();
          });
          canvas.addEventListener('webglcontextlost',e=>{ e.preventDefault(); stopKeys(); stopPointers(); fallback('Interactive graphics were interrupted. Reload to try again.'); });
          new ResizeObserver(schedule).observe(viewport);
          canvas.hidden=false; flat.hidden=true;
          reset.disabled=zoom.disabled=toggle.disabled=false;
          status.textContent=exploreHint;
          draw();
        } catch (_) { fallback('The interactive view could not start.'); }
      }
      if (document.fullscreenEnabled) {
        fullscreen.hidden=false;
        fullscreen.addEventListener('click',async()=>{
          try { if (document.fullscreenElement) await document.exitFullscreen(); else await stage.requestFullscreen(); }
          catch (_) { status.textContent='Full screen is unavailable. You can still explore in this window.'; }
        });
        document.addEventListener('fullscreenchange',()=>{
          const label=document.fullscreenElement?'Exit full screen':'Enter full screen';
          fullscreen.title=label; fullscreen.setAttribute('aria-label',label);
        });
      }
      if (flat.complete) start(); else { flat.addEventListener('load',start,{once:true}); flat.addEventListener('error',()=>fallback('The embedded image could not be read.'),{once:true}); }
    })();
    </script>
    </html>
    """#
}
