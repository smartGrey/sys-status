import Foundation
import Security

@objc protocol SleepServiceProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void)
}

enum SleepService {
    static let label = "com.smartgrey.netrate.sleep-helper"
    static let appIdentifier = "com.smartgrey.netrate"

    static func signingRequirement(for identifier: String) -> String? {
        var runningCode: SecCode?
        var signedCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode,
              SecCodeCopyStaticCode(runningCode, [], &signedCode) == errSecSuccess, let signedCode,
              SecCodeCopySigningInformation(signedCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String,
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { return nil }
        return signingRequirement(for: identifier, team: team)
    }

    static func signingRequirement(for identifier: String, team: String) -> String {
        """
        anchor apple generic and identifier "\(identifier)" and certificate leaf[subject.OU] = "\(team)"
        and !(entitlement["com.apple.security.get-task-allow"] exists)
        and !(entitlement["com.apple.security.cs.disable-library-validation"] exists)
        """
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
