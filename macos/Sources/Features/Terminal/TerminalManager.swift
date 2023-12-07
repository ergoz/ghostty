import Cocoa
import SwiftUI
import GhosttyKit
import Combine

/// Manages a set of terminal windows. This is effectively an array of TerminalControllers.
/// This abstraction helps manage tabs and multi-window scenarios.
class TerminalManager {
    struct Window {
        let controller: TerminalController
        let closePublisher: AnyCancellable
    }
    
    let ghostty: Ghostty.AppState
    
    /// The currently focused surface of the main window.
    var focusedSurface: Ghostty.SurfaceView? { mainWindow?.controller.focusedSurface }
    
    /// The set of windows we currently have.
    var windows: [Window] = []
    
    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)
    
    /// Returns the main window of the managed window stack. If there is no window
    /// then an arbitrary window will be chosen.
    private var mainWindow: Window? {
        for window in windows {
            if (window.controller.window?.isMainWindow ?? false) {
                return window
            }
        }
        
        // If we have no main window, just use the first window.
        return windows.first
    }
    
    init(_ ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNewWindow),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
    }
    
    deinit {
        let center = NotificationCenter.default
        center.removeObserver(self)
    }
    
    // MARK: - Window Management
    
    /// Create a new terminal window.
    func newWindow(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        let c = createWindow(withBaseConfig: base)
        if let window = c.window {
            Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
        }
        
        if (ghostty.windowFullscreen) {
            // NOTE: this doesn't properly handle non-native fullscreen yet
            c.window?.toggleFullScreen(nil)
        }
        
        c.showWindow(self)
    }
    
    /// Creates a new tab in the current main window. If there are no windows, a window
    /// is created.
    func newTab(withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        // If there is no main window, just create a new window
        guard let parent = mainWindow?.controller.window else {
            newWindow(withBaseConfig: base)
            return
        }
        
        // Create a new window and add it to the parent
        newTab(to: parent, withBaseConfig: base)
    }
    
    private func newTab(to parent: NSWindow, withBaseConfig base: Ghostty.SurfaceConfiguration?) {
        // Create a new window and add it to the parent
        let controller = createWindow(withBaseConfig: base)
        let window = controller.window!
        
        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if (parent.isMiniaturized) { parent.deminiaturize(self) }
        
        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup, tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }
        
        // Add the window to the tab group and show it
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(self)
        
        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }
    }
    
    /// Creates a window controller, adds it to our managed list, and returns it.
    private func createWindow(withBaseConfig base: Ghostty.SurfaceConfiguration?) -> TerminalController {
        // Initialize our controller to load the window
        let c = TerminalController(ghostty, withBaseConfig: base)

        // Create a listener for when the window is closed so we can remove it.
        let pubClose = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification,
            object: c.window!
        ).sink { notification in
            guard let window = notification.object as? NSWindow else { return }
            guard let c = window.windowController as? TerminalController else { return }
            self.removeWindow(c)
        }
        
        // Keep track of every window we manage
        windows.append(Window(
            controller: c,
            closePublisher: pubClose
        ))
        
        return c
    }
    
    private func removeWindow(_ controller: TerminalController) {
        // Remove it from our managed set
        guard let idx = self.windows.firstIndex(where: { $0.controller == controller }) else { return }
        let w = self.windows[idx]
        self.windows.remove(at: idx)
        
        // Ensure any publishers we have are cancelled
        w.closePublisher.cancel()
        
        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != controller.window {
                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: NSZeroPoint)
                return
            }
            
            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }
    
    /// Relabels all the tabs with the proper keyboard shortcut.
    func relabelAllTabs() {
        for w in windows {
            w.controller.relabelTabs()
        }
    }
    
    // MARK: - Notifications
    
    @objc private func onNewWindow(notification: SwiftUI.Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        self.newWindow(withBaseConfig: config)
    }
    
    @objc private func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        
        self.newTab(to: window, withBaseConfig: config)
    }
}
