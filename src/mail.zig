//! Mailboxes and email messages: git's `mailsplit` and `mailinfo`, and
//! the patch email git writes.

pub const engine = @import("mail/mail.zig");
pub const format = @import("mail/format.zig");
