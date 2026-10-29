import AppKit

// `DeskSkate --render-demo <outdir>`: render the landing-page demo offscreen and exit.
if DemoRender.runIfRequested() { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
