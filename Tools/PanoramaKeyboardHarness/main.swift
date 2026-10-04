import Foundation
import CoreGraphics
import JavaScriptCore

// Execute the actual generated viewer in JavaScriptCore with a deterministic
// clock and DOM/WebGL doubles. This checks motion and lifecycle, not GPU output.
@main struct KeyboardChecks {
    static func main() throws {
        let context = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        var failures = 0, checks = 0
        func run(embedded: Bool, sweep: Double = 360) throws -> JSContext {
            let html = try InteractivePanoramaWriter.document(panorama: image, sweepDegrees: sweep, embedded: embedded)
            let script = String(html.components(separatedBy: "<script>")[1].components(separatedBy: "</script>")[0])
            let js = JSContext()!
            js.exceptionHandler = { _, error in fatalError("JavaScript error: \(error?.toString() ?? "unknown")") }
            js.evaluateScript(environment)
            js.evaluateScript("const nativeStates=[]; window.webkit={messageHandlers:{panoramaState:{postMessage:state=>nativeStates.push(state)}}};")
            js.evaluateScript(script)
            return js
        }
        func check(_ js: JSContext, _ expression: String, _ message: String) {
            checks += 1
            let passed = js.evaluateScript(expression)!.toBool()
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL"): \(message)")
        }
        for embedded in [false, true] {
            let js = try run(embedded: embedded)
            let label = embedded ? "embedded" : "exported"
            check(js, "draws.length===1 && frames.size===0", "\(label): initial draw needs no animation callback")
            js.evaluateScript("key('ArrowRight'); release('ArrowRight'); advance(400,60)")
            check(js, "Math.abs(pose.yaw/pose.hfov-.025)<.0002", "\(label): small tap has predictable travel")
            check(js, "frames.size===0", "\(label): animation stops after tap settles")
            js.evaluateScript("resetView(); draws.length=0; key('ArrowRight'); advance(1000,60); release('ArrowRight'); advance(400,60)")
            check(js, "Math.abs(pose.yaw/pose.hfov-.675)<.002", "\(label): hold travels at elapsed-time speed")
            check(js, "draws.every((v,i)=>i===0 || Math.abs(v.yaw-draws[i-1].yaw)<pose.hfov*.02)", "\(label): held motion uses small frame increments")
            js.evaluateScript("const at60=pose.yaw; resetView(); key('ArrowRight'); advance(1000,120); release('ArrowRight'); advance(400,120)")
            check(js, "Math.abs(pose.yaw-at60)<pose.hfov*.002", "\(label): 60/120 Hz produce equivalent travel")
            js.evaluateScript("resetView(); key('ArrowRight'); for(let i=0;i<30;i++) key('ArrowRight',true); advance(1000,60); release('ArrowRight'); advance(400,60)")
            check(js, "Math.abs(pose.yaw-at60)<pose.hfov*.002", "\(label): OS repeat does not change speed")
            js.evaluateScript("resetView(); key('ArrowLeft'); advance(1000,60); release('ArrowLeft'); advance(400,60)")
            check(js, "Math.abs(pose.yaw+at60)<pose.hfov*.002", "\(label): opposite directions are symmetric")
            for event in ["blur", "pagehide", "visibilitychange", "canvasBlur", "contextLost"] {
                let fresh = try run(embedded: embedded)
                fresh.evaluateScript("key('ArrowRight'); advance(100,60); stopEvent('\(event)'); const stopped=pose.yaw; advance(1000,60)")
                check(fresh, "frames.size===0 && pose.yaw===stopped", "\(label): \(event) stops movement")
            }
            js.evaluateScript("resetView(); key('ArrowRight'); advance(100,60); resetView(); advance(1000,60)")
            check(js, "pose.yaw===0 && frames.size===0", "\(label): reset cancels held movement")
            js.evaluateScript("key('ArrowRight'); advance(100,60); emit(elements.flatToggle,'click'); advance(1000,60)")
            check(js, "frames.size===0 && elements.view.hidden", "\(label): Overview stops movement")
            let reduced = try run(embedded: embedded)
            reduced.evaluateScript("motion.matches=true; key('ArrowRight'); advance(100,60); release('ArrowRight'); advance(17,60); const stopped=pose.yaw; advance(500,60)")
            check(reduced, "frames.size===0 && pose.yaw===stopped", "\(label): reduced motion has no easing tail")
            let delayed = try run(embedded: embedded)
            delayed.evaluateScript("key('ArrowRight'); tick(5000)")
            check(delayed, "pose.yaw<pose.hfov*.06", "\(label): delayed callback cannot jump across panorama")
            delayed.evaluateScript("resetView(); emit(elements.view,'keydown',{key:'ArrowRight',metaKey:true,preventDefault(){}}); advance(100,60)")
            check(delayed, "pose.yaw===0 && frames.size===0", "\(label): command shortcuts do not pan")

            let native = try run(embedded: embedded)
            check(native, "nativeStates.length===1 && nativeStates[0].zoom===1 && nativeStates[0].available", "\(label): initial zoom is reported to native controls")
            native.evaluateScript("window.swiftTakePanorama.setZoom(2)")
            check(native, "elements.zoom.value==='2' && nativeStates.at(-1).zoom===2", "\(label): native slider updates projection and reports zoom")
            native.evaluateScript("const count=nativeStates.length; window.swiftTakePanorama.setZoom(NaN); window.swiftTakePanorama.setZoom(Infinity)")
            check(native, "nativeStates.length===count && elements.zoom.value==='2'", "\(label): invalid native zoom is ignored")
            native.evaluateScript("window.swiftTakePanorama.reset()")
            check(native, "elements.zoom.value==='1' && nativeStates.at(-1).zoom===1 && pose.yaw===0", "\(label): native reset restores view and zoom")
            native.evaluateScript("const beforePan=nativeStates.length; wheel(60,0)")
            check(native, "nativeStates.length===beforePan", "\(label): panning does not flood native zoom updates")

            let trackpad = try run(embedded: embedded)
            trackpad.evaluateScript("wheel(80,2)")
            check(trackpad, "Math.abs(pose.yaw/pose.hfov-.1)<.0001 && elements.zoom.value==='1'",
                  "\(label): horizontal scroll pans without zoom from vertical drift")
            trackpad.evaluateScript("wheel(-80,-2)")
            check(trackpad, "Math.abs(pose.yaw)<.0001", "\(label): opposite swipe returns to the same view")
            trackpad.evaluateScript("wheel(1,-100)")
            check(trackpad, "Number(elements.zoom.value)>1 && Math.abs(pose.yaw)<.0001",
                  "\(label): vertical scroll retains zoom without sideways drift")
            trackpad.evaluateScript("resetView(); wheel(100,-10,0,true)")
            check(trackpad, "Number(elements.zoom.value)>1 && pose.yaw===0",
                  "\(label): pinch wheel events zoom even with horizontal drift")
            trackpad.evaluateScript("resetView(); gesture('gesturestart'); gesture('gesturechange',2)")
            check(trackpad, "Number(elements.zoom.value)===2 && pose.yaw===0", "\(label): Safari pinch scales the panorama without panning")
            trackpad.evaluateScript("wheel(0,-100,0,true)")
            check(trackpad, "Number(elements.zoom.value)===2", "\(label): duplicate wheel input cannot double a Safari pinch")
            trackpad.evaluateScript("gesture('gesturechange',1.5); gesture('gestureend'); gesture('gesturestart'); gesture('gesturechange',2); gesture('gestureend')")
            check(trackpad, "Number(elements.zoom.value)===3", "\(label): successive Safari pinches retain their own starting zoom")
            trackpad.evaluateScript("gesture('gesturestart'); gesture('gesturechange',Infinity); gesture('gesturechange',NaN)")
            check(trackpad, "Number(elements.zoom.value)===3", "\(label): malformed gesture scales cannot poison zoom")
            trackpad.evaluateScript("gesture('gesturechange',100)")
            check(trackpad, "Number(elements.zoom.value)===4", "\(label): pinch zoom respects the maximum")
            trackpad.evaluateScript("gesture('gesturechange',.001); gesture('gestureend')")
            check(trackpad, "Number(elements.zoom.value)===1", "\(label): pinch zoom respects the minimum")
            trackpad.evaluateScript("pointer('pointerdown',1,100,100); pointer('pointerdown',2,200,100); pointer('pointermove',2,300,100)")
            check(trackpad, "Number(elements.zoom.value)===2 && pose.yaw===0", "\(label): two touch pointers pinch instead of rotating")
            trackpad.evaluateScript("gesture('gesturestart'); gesture('gesturechange',2); gesture('gestureend')")
            check(trackpad, "Number(elements.zoom.value)===2", "\(label): Safari touch gesture does not duplicate pointer pinch")
            trackpad.evaluateScript("pointer('pointerup',2,300,100); pointer('pointermove',1,100,100)")
            check(trackpad, "pose.yaw===0", "\(label): lifting one finger resumes drag without jumping")
            trackpad.evaluateScript("pointer('pointermove',1,120,100)")
            check(trackpad, "pose.yaw<0 && Number(elements.zoom.value)===2", "\(label): one remaining finger pans normally")
            trackpad.evaluateScript("pointer('pointercancel',1,120,100); pointer('pointermove',1,500,100); const afterCancel=pose.yaw; wheel(0,-20)")
            check(trackpad, "pose.yaw===afterCancel && Number(elements.zoom.value)>2", "\(label): cancelled touch releases zoom ownership")
            trackpad.evaluateScript("resetView(); gesture('gesturestart'); stopEvent('blur'); wheel(0,-100)")
            check(trackpad, "Number(elements.zoom.value)>1", "\(label): focus loss clears Safari gesture state")
            trackpad.evaluateScript("resetView(); wheel(5,0,1)")
            check(trackpad, "Math.abs(pose.yaw/pose.hfov-.1)<.0001",
                  "\(label): line-based horizontal scrolling uses normalized distance")
            trackpad.evaluateScript("resetView(); wheel(.1,0,2)")
            check(trackpad, "Math.abs(pose.yaw/pose.hfov-.1)<.0001",
                  "\(label): page-based horizontal scrolling uses viewport width")
            trackpad.evaluateScript("resetView(); key('ArrowRight'); wheel(80,0); const afterWheel=pose.yaw; advance(500,60)")
            check(trackpad, "frames.size===0 && pose.yaw===afterWheel",
                  "\(label): trackpad takes over from keyboard motion without a lingering tail")
            trackpad.evaluateScript("resetView(); for(let i=0;i<100;i++) wheel(800,0)")
            check(trackpad, "Number.isFinite(pose.yaw) && Math.abs(pose.yaw)<=Math.PI",
                  "\(label): full-circle scrolling wraps safely")
        }
        let partial = try run(embedded: true, sweep: 90)
        partial.evaluateScript("key('ArrowRight'); advance(10000,60); release('ArrowRight'); advance(500,60)")
        check(partial, "pose.yaw<= (Math.PI/2-pose.hfov)/2+.0001 && frames.size===0", "partial panorama stays within its edges")
        partial.evaluateScript("wheel(100000,0)")
        check(partial, "Math.abs(pose.yaw-(Math.PI/2-pose.hfov)/2)<.0001", "horizontal scroll stops at the right edge of a partial panorama")
        partial.evaluateScript("wheel(-100000,0)")
        check(partial, "Math.abs(pose.yaw+(Math.PI/2-pose.hfov)/2)<.0001", "horizontal scroll stops at the left edge of a partial panorama")
        let vertical = try run(embedded: true)
        vertical.evaluateScript("elements.zoom.value='2'; emit(elements.zoom,'input'); key('ArrowUp'); advance(100,60); release('ArrowUp'); advance(400,60)")
        check(vertical, "pose.pitch>0 && Number.isFinite(pose.pitch)", "up arrow moves vertically when zoom permits")
        print("\(checks-failures)/\(checks) panorama keyboard checks passed")
        if failures > 0 { exit(1) }
    }

    static let environment = #"""
    let now=0, nextFrame=1, frames=new Map(), draws=[], pose={}, motion={matches:false};
    function target(){ return {listeners:{},hidden:false,disabled:false,value:'1',clientWidth:800,clientHeight:400,
      addEventListener(n,f){(this.listeners[n]??=[]).push(f)},setAttribute(){},focus(){},
      setPointerCapture(){},classList:{add(){},remove(){}}}; }
    function emit(t,n,e={}){ for(const f of t.listeners[n]??[]) f(e); }
    const elements=Object.fromEntries(['coverage','view','flat','stage','viewport','status','zoom','reset','flatToggle','fullscreen'].map(n=>[n,target()]));
    elements.flat.complete=true; elements.flat.naturalWidth=800; elements.flat.naturalHeight=200;
    const gl=new Proxy({MAX_TEXTURE_SIZE:1,MAX_RENDERBUFFER_SIZE:2,NO_ERROR:0,
      getParameter(n){return 8192},getShaderParameter(){return true},getProgramParameter(){return true},getError(){return 0},
      getUniformLocation(p,n){return n},isContextLost(){return false},uniform1f(n,v){pose[n]=v},drawArrays(){draws.push({...pose})}},
      {get(o,n){return n in o?o[n]:(()=>({}))}});
    elements.view.getContext=()=>gl;
    const document=Object.assign(target(),{hidden:false,fullscreenEnabled:false,getElementById:n=>elements[n]});
    const window=Object.assign(target(),{devicePixelRatio:1,matchMedia:()=>motion});
    const performance={now:()=>now};
    function requestAnimationFrame(f){const id=nextFrame++;frames.set(id,f);return id}
    function cancelAnimationFrame(id){frames.delete(id)}
    class ResizeObserver {constructor(f){} observe(){}}
    function tick(ms){now+=ms;const pending=[...frames.values()];frames.clear();for(const f of pending)f(now)}
    function advance(ms,hz){const n=Math.ceil(ms*hz/1000);for(let i=0;i<n;i++)tick(ms/n)}
    function key(key,repeat=false){emit(elements.view,'keydown',{key,repeat,preventDefault(){}})}
    function release(key){emit(window,'keyup',{key})}
    function wheel(deltaX,deltaY,deltaMode=0,ctrlKey=false){emit(elements.view,'wheel',{deltaX,deltaY,deltaMode,ctrlKey,preventDefault(){}})}
    function gesture(type,scale=1){emit(elements.view,type,{scale,preventDefault(){}})}
    function pointer(type,pointerId,clientX,clientY){emit(elements.view,type,{pointerId,clientX,clientY,pointerType:'touch',button:0})}
    function resetView(){emit(elements.reset,'click')}
    function stopEvent(event){
      if(event==='visibilitychange'){document.hidden=true;emit(document,event)}
      else if(event==='canvasBlur')emit(elements.view,'blur');
      else if(event==='contextLost')emit(elements.view,'webglcontextlost',{preventDefault(){}});
      else emit(window,event);
    }
    """#
}
