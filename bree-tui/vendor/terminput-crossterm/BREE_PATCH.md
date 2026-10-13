# bree terminput-crossterm patch

This is `terminput-crossterm` 0.4.7 from crates.io.

bree vendors it because `vendor/crossterm` adds `Event::EnhancedKey`, which is
outside Crossterm 0.29's published enum. The adapter maps that variant through
its embedded `KeyEvent`; bree consumes the additional layout and text fields
through its direct enhanced-input path.
