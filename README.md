# TouchTiles

TouchTiles is a native Mac menu bar app for Omarchy-style Dwindle tiling. Each display keeps its own layout. Rest the pointer over a window to focus it. Hold Command to change its size or position with the trackpad.

## Set up the app

1. Clone this repository and run `./build-app.sh` from its root. Move `dist/TouchTiles.app` to Applications and open it. The split-rectangle icon opens the menu. Tiling starts off on the first launch.
2. Open **Settings → Desktop → Grant access**. On macOS 27 the privacy pane is called **Device Control and Data Access**. Earlier releases call it **Accessibility**. Enable the installed app, confirm TouchTiles says **Allowed**, then turn on **Automatic tiling**. If the trackpad status reports blocked input, allow TouchTiles under **Input Monitoring** and reopen it.
3. To launch with your Mac, turn on **Open at login**. If macOS asks for approval, follow **Approve TouchTiles in Login Items**. TouchTiles remembers whether tiling was on when you quit.

## Use the controls

| Action | Default input |
| --- | --- |
| Focus a window | Move the pointer over it. The focused window gets a two-point outline. |
| Resize a window | Place the pointer in the quarter you want to grab. Hold ⌘ and slide two fingers together. Slide sideways to change the width, up or down to change the height, or diagonally to change both. |
| Move a window | Hold ⌘ and swipe with three fingers. The pointer stays where you grabbed the window as it moves. Neighboring tiles slide aside as you cross them. |
| Float or retile a window | ⌥T |
| Fill the current display or return to your layout | ⌥F |
| Return to standard macOS window management | Choose **Turn Tiling Off** in the menu bar. |

In **Settings → Controls**, record a shortcut by holding Option or two or more modifiers and pressing a key. You can also change the trackpad modifier here. TouchTiles checks enabled system shortcuts and registered global hotkeys. When tiling is on, the assigned Option combinations take precedence over typing their alternate characters. ⌘T and ⌘F stay available to your apps. If a binding collides with a shortcut inside an app, use the menu command and choose another combination.

Turn tiling off to release the global shortcuts, close the trackpad streams, remove the focus outline, and restore the frames TouchTiles changed. Floating windows move freely. When you resize one, its opposite corner stays in place. If the pointer’s proportional position falls offscreen, TouchTiles uses the closest visible point in the same quarter, or the closest visible point in the window if the whole quarter is offscreen.

TouchTiles Settings stays above tiles while you work in another window. You can cross a tile to reach an open menu, sheet, or utility panel. Hover focus waits while raising the tile would cover the panel or dismiss it. Close the panel and the tile under the pointer can take focus again.

For a window you floated with ⌥T, or one that couldn’t fit in the layout, turn on **Settings → Desktop → Show covered floating windows** and grant Screen Recording access to keep it visible over a focused tile. TouchTiles displays a local live preview of the covered window. Hover over it to bring the original window forward for typing, clicking, or dragging. Turning the feature off stops the previews.

## How the layout behaves

TouchTiles adopts the windows already on screen by splitting the largest tile first. macOS doesn’t expose the order in which those windows gained focus. After that first pass, each new window splits the active tile to the right or below. Split directions persist as the layout resizes. The outer gap is normally 10 points, and adjacent tiles each contribute a five-point inner gap. When the windows need that space, TouchTiles narrows the gaps on the tight axis. [Omarchy’s defaults](https://github.com/omacom/omarchy/blob/quattro/default/hypr/looknfeel.lua) · [Hyprland’s Dwindle layout](https://wiki.hypr.land/configuring/layouts/dwindle-layout/)

**Settings → Desktop → Layout per display** sets the maximum rows and columns for each display’s active Space. The defaults are **2 rows and 8 columns**. If a split would exceed the cap or make a window too small, TouchTiles tries the other direction and then other tiles. If none fits, the extra window floats. The oldest waiting window that fits takes the next free slot.

When an app refuses to shrink, TouchTiles uses the size it accepts to stop the divider. Two windows stacked in a column share the larger of their minimum widths. Windows side by side share the larger of their minimum heights. For example, if two stacked windows need 320 and 480 points of width, the column stops at 480. You can still resize it vertically, and closing the 480-point window frees the column to shrink further.

Hyprland chooses the resize corner by dividing the window into four quarters at the start of the drag. TouchTiles keeps the pointer at the same proportional position in the window throughout a resize. If you start a quarter of the way across and a quarter of the way down, the pointer stays there as the window grows or shrinks. Lift your fingers and scroll again to keep using that corner, or move the pointer to choose another. A tiled edge at the display boundary uses the available interior divider. An axis already spanning the entire display stays fixed. Lifting your fingers stops the resize immediately, including when macOS generates scroll momentum. [Hyprland’s drag controller](https://github.com/hyprwm/Hyprland/blob/main/src/layout/supplementary/DragController.cpp) · [Dwindle smart resizing](https://github.com/hyprwm/Hyprland/blob/main/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp)

During a three-finger move, the window keeps its size. When you lift, a tiled window fits its new slot and the pointer stays at the same fraction of its width and height. A floating window stays where you placed it, with the pointer at the same spot inside it. You can swipe again from there.

When you close a tile, neighboring windows slide and resize to fill the gap. If you enable Reduce Motion in macOS, they move straight to their new frames.

Press ⌥F to expand the focused window on its current display and Space. TouchTiles requests the full display frame. macOS can reserve room for the menu bar and Dock. Press ⌥F again to return to the window’s tile, or to its previous frame if it was floating. If a neighbor closed while the window was expanded, it returns to the enlarged tile.

TouchTiles tiles visible, resizable app windows inside the display’s usable frame. Sheets, dialogs, minimized windows, and apps in native full screen keep their macOS behavior.

TouchTiles claims matching trackpad streams while tiling is active. It leaves system gesture preferences alone. If a three-finger swipe also changes Spaces or opens Mission Control or App Exposé, assign the competing gesture to **four fingers** under **System Settings → Trackpad → More Gestures**. If it selects text, check **Accessibility → Pointer Control → Trackpad Options → Dragging style**. These manual system settings apply outside TouchTiles too. [Apple’s trackpad gestures](https://support.apple.com/en-us/102482) · [Apple’s three-finger drag setting](https://support.apple.com/en-us/102341)

## Build and test

TouchTiles targets macOS 13 or later. To build for your Mac, use Xcode 15 or later with Swift 5.9 or later. The package has no external dependencies.

```sh
./build-app.sh
swift test
```

The script writes `dist/TouchTiles.app` and signs it locally. Set `TOUCHTILES_SIGN_IDENTITY` to a stable code-signing identity for rebuilds. With the default ad-hoc signature, macOS can ask you to grant permissions again after the executable changes.

To exercise real windows, run `./Integration/test-windows.sh` in a logged-in session from an Accessibility-authorized terminal. The fixture opens disposable windows, including windows that enforce minimum sizes. Its window manager filters the inventory to the fixture processes before making Accessibility calls.

Window identity, Space IDs, and raw multitouch contacts use dynamically resolved private macOS interfaces. An OS update can change those interfaces. The tests exercise layout geometry, shortcut validation, gesture recognition, and the window lifecycle. Finger recognition and arbitration with the Dock still need a physical gesture check on each supported macOS release.
