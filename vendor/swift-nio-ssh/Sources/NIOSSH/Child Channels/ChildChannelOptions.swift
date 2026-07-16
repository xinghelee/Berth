//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// The various channel options specific to `SSHChildChannel`s.
///
/// Please note that some of NIO's regular `ChannelOptions` are valid on `SSHChildChannel`s.
public enum SSHChildChannelOptions {
    /// - seealso: `LocalChannelIdentifierOption`.
    public static let localChannelIdentifier: SSHChildChannelOptions.Types.LocalChannelIdentifierOption = .init()

    /// - seealso: `RemoteChannelIdentifierOption`.
    public static let remoteChannelIdentifier: SSHChildChannelOptions.Types.RemoteChannelIdentifierOption = .init()

    /// - seealso: `SSHChannelTypeOption`.
    public static let sshChannelType: SSHChildChannelOptions.Types.SSHChannelTypeOption = .init()

    /// - seealso: `PeerMaximumMessageLengthOption`.
    public static let peerMaximumMessageLength: SSHChildChannelOptions.Types.PeerMaximumMessageLengthOption = .init()
    
    /// - seealso: `UsernameOption`.
    public static let username: SSHChildChannelOptions.Types.UsernameOption = .init()
}

public extension SSHChildChannelOptions {
    enum Types {}
}

public extension SSHChildChannelOptions.Types {
    /// `LocalChannelIdentifierOption` allows users to query the channel number assigned locally for a given channel.
    struct LocalChannelIdentifierOption: ChannelOption, NIOSSHSendable {
        public typealias Value = UInt32

        public init() {}
    }

    /// `RemoteChannelIdentifierOption` allows users to query the channel number assigned by the remote peer for a given channel.
    struct RemoteChannelIdentifierOption: ChannelOption, NIOSSHSendable {
        public typealias Value = UInt32?

        public init() {}
    }

    /// `SSHChannelTypeOption` allows users to query the type of the channel they're currently using.
    struct SSHChannelTypeOption: ChannelOption, NIOSSHSendable {
        public typealias Value = SSHChannelType

        public init() {}
    }

    /// `PeerMaximumMessageLengthOption` allows users to query the maximum packet size value reported by the remote peer for a given channel.
    struct PeerMaximumMessageLengthOption: ChannelOption, NIOSSHSendable {
        public typealias Value = UInt32
        
        public init() {}
    }
    
    /// `UsernameOption` allows users to query the authenticated username of the channel.
    public struct UsernameOption: ChannelOption {
        public typealias Value = String?
        
        public init() {}
    }
}
