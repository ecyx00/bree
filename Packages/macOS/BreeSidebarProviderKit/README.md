# BreeSidebarProviderKit

Internal app-side kit for bree-owned sidebar providers.

Use this package for in-process sidebar render models, sidebar provider descriptors, and provider mutations that run inside the bree app. It is not the public extension SDK for third-party sidebar app extensions, and all types use `BreeSidebarProvider` naming to keep that boundary visible.

External extension authors should import `BreeExtensionKit` instead.
