import CoreMediaIO
import Foundation

// Entry point of the MemeCam CMIO camera extension (a system extension run by the system, not by the app).
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
