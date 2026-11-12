/// Decides whether to show the setup alert at launch. The offer is made once ever:
/// after the first launch the caller records that it happened, whatever the answer.
enum SetupOffer {
    static func shouldOffer(alreadyOffered: Bool, launchedAsLoginItem: Bool, isWorking: Bool, receivedLink: Bool) -> Bool {
        !alreadyOffered && !launchedAsLoginItem && !isWorking && !receivedLink
    }
}
