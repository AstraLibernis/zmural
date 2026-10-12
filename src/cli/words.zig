// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What an error means, in words a user reads in zmural-console's messages,
//! instead of its name. Unknown ones keep their name.

const std = @import("std");

pub fn of(err: anyerror) []const u8 {
    const table = .{
        // Command lines.
        .{ "MissingCommand", "no command given" },
        .{ "UnknownCommand", "there is no such command" },
        .{ "MissingArgument", "that command needs more after it" },
        .{ "UnexpectedArgument", "that command takes fewer words after it" },
        .{ "BadValue", "a value it can't use" },
        // Files.
        .{ "FileNotFound", "no such file" },
        .{ "AccessDenied", "permission denied" },
        .{ "PermissionDenied", "permission denied" },
        .{ "IsDir", "that is a folder" },
        .{ "NotDir", "a part of the path isn't a folder" },
        .{ "NameTooLong", "the name is too long" },
        .{ "NoSpaceLeft", "the disk is full" },
        .{ "StreamTooLong", "it is too large" },
        .{ "ReadOnlyFileSystem", "the disk is read-only" },
        // A package's zmural.toml.
        .{ "SyntaxError", "it isn't written the way the format needs" },
        .{ "UnsafeEntry", "it names a file outside its own folder" },
        .{ "EntryNotType", "its type doesn't match the file it names" },
        .{ "MissingField", "it lacks a title, type or entry" },
        .{ "UnknownKey", "it has a setting zmural doesn't know" },
        .{ "UnknownTable", "it has a section zmural doesn't know" },
        .{ "InvalidProperty", "one of its properties isn't valid" },
        .{ "TooManyProperties", "it has too many properties" },
        // Talking to zmural.
        .{ "BodyTooLarge", "that is too long to send to zmural" },
        .{ "Disconnected", "the connection closed" },
        .{ "WouldBlock", "no answer in time" },
        .{ "Timeout", "no answer in time" },
    };
    const name = @errorName(err);
    inline for (table) |t| if (std.mem.eql(u8, name, t[0])) return t[1];
    return name;
}

test of {
    try std.testing.expectEqualStrings("there is no such command", of(error.UnknownCommand));
    try std.testing.expectEqualStrings("it is too large", of(error.StreamTooLong));
    try std.testing.expectEqualStrings("SomethingNew", of(error.SomethingNew));
}
