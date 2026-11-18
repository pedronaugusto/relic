//! What stands for uplink and cloak in `check-offline`: a compilation that
//! reaches either stops here. relic's core calls the network only through
//! the `transport.Means` an operation is given, so a program over `relic`
//! and `relic_lfs` alone never reaches this file.
comptime {
    @compileError("uplink or cloak reached without relic_net: relic's core reaches the network only through a transport.Means");
}
