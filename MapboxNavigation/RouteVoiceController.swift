import Foundation
import AVFoundation
import MapboxDirections
import AWSPolly

public class RouteVoiceController: NSObject, AVSpeechSynthesizerDelegate {
    
    lazy var speechSynth = AVSpeechSynthesizer()
    let audioPlayer = AVPlayer()
    let maneuverVoiceDistanceFormatter = DistanceFormatter(approximate: true, forVoiceUse: true)
    let routeStepFormatter = RouteStepFormatter()
    var recentlyAnnouncedRouteStep: RouteStep?
    var fallbackText: String!
    var useDefaultVoice: Bool
    
    
    /**
     Volume of audioPlayer. Used only for Polly instructions.
     */
    public var volume: Float {
        get {
            return audioPlayer.volume
        }
        set {
            audioPlayer.volume = newValue
        }
    }
    
    
    /**
     Forces Polly voice to always be of specified type. If not set, a localized voice will be used
     */
    public var globalVoiceId: AWSPollyVoiceId?
    
    
    /**
     SSML option which controls at which speed Polly instructions are read.
     */
    public var instructionVoiceSpeedRate = 1.08
    
    
    /**
     SSML option that specifies the voice loudness.
     */
    public var instructionVoiceVolume = "x-loud"
    
    
    public init(regionType: AWSRegionType = AWSRegionType.USEast1, identityPoolId: String?) {
        if let identityPoolId = identityPoolId {
            self.useDefaultVoice = false
            let credentialsProvider = AWSCognitoCredentialsProvider(regionType:regionType, identityPoolId: identityPoolId)
            let configuration = AWSServiceConfiguration(region:regionType, credentialsProvider:credentialsProvider)
            AWSServiceManager.default().defaultServiceConfiguration = configuration
        } else {
            self.useDefaultVoice = true
        }
        super.init()
        maneuverVoiceDistanceFormatter.unitStyle = .long
        resumeNotifications()
    }
    
    deinit {
        if let currentItem = audioPlayer.currentItem {
            currentItem.removeObserver(self, forKeyPath: "status")
        }
        suspendNotifications()
        speechSynth.stopSpeaking(at: .word)
    }
    
    func resumeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(alertLevelDidChange(notification:)), name: RouteControllerAlertLevelDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reRoute(notification:)), name: RouteControllerShouldReroute, object: nil)
        NotificationCenter.default.addObserver(self, selector:#selector(audioPlayerDidFinishPlaying(notification:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: audioPlayer.currentItem)
    }
    
    public func suspendNotifications() {
        NotificationCenter.default.removeObserver(self, name: RouteControllerAlertLevelDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: RouteControllerShouldReroute, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: nil)
    }
    
    public func stopVoice() {
        speechSynth.stopSpeaking(at: .word)
    }
    
    func reRoute(notification: NSNotification) {
        stopVoice()
    }
    
    func audioPlayerDidFinishPlaying(notification: NSNotification) {
        do {
            try unDuckAudio()
        } catch {
            print(error)
        }
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        do {
            try unDuckAudio()
        } catch {
            print(error)
        }
    }
    
    func validateNavigationVoiceOptions() throws {
        let category = AVAudioSessionCategoryPlayback
        if #available(iOS 9.0, *) {
            let categoryOptions: AVAudioSessionCategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            try AVAudioSession.sharedInstance().setMode(AVAudioSessionModeSpokenAudio)
            try AVAudioSession.sharedInstance().setCategory(category, with: categoryOptions)
        }
    }
    
    func duckAudio() throws {
        try validateNavigationVoiceOptions()
        try AVAudioSession.sharedInstance().setActive(true)
    }
    
    func unDuckAudio() throws {
        if !speechSynth.isSpeaking {
            try AVAudioSession.sharedInstance().setActive(false, with: [.notifyOthersOnDeactivation])
        }
    }
    
    func alertLevelDidChange(notification: NSNotification) {
        guard let routeProgress = notification.userInfo![RouteControllerAlertLevelDidChangeNotificationRouteProgressKey] as? RouteProgress else {
            assert(false)
            return
        }
        
        // We're guarding against two things here:
        //   1. `recentlyAnnouncedRouteStep` being nil.
        //   2. `recentlyAnnouncedRouteStep` being equal to currentStep
        // If it has a value and they're equal, this means we gave an announcement with x seconds ago for this step
        guard recentlyAnnouncedRouteStep != routeProgress.currentLegProgress.currentStep else {
            return
        }
        
        // Set recentlyAnnouncedRouteStep to the current step
        recentlyAnnouncedRouteStep = routeProgress.currentLegProgress.currentStep
        
        if useDefaultVoice {
            speakFallBack(speechString(notification: notification, markUpWithSSML: false))
        } else {
            speakWithPolly(speechString(notification: notification, markUpWithSSML: true))
        }
    }
    
    func speechString(notification: NSNotification, markUpWithSSML: Bool) -> String {
        let routeProgress = notification.userInfo![RouteControllerAlertLevelDidChangeNotificationRouteProgressKey] as! RouteProgress
        let userDistance = notification.userInfo![RouteControllerAlertLevelDidChangeNotificationDistanceToEndOfManeuverKey] as! CLLocationDistance
        let alertLevel = routeProgress.currentLegProgress.alertUserLevel
        
        let escapeIfNecessary = {(distance: String) -> String in
            return markUpWithSSML ? distance.addingXMLEscapes : distance
        }
        
        // Handle arriving at the final destination
        guard let followOnInstruction = routeStepFormatter.string(for: routeProgress.currentLegProgress.followOnStep, markUpWithSSML: markUpWithSSML) else {
            let upComingStepInstruction = routeStepFormatter.string(for: routeProgress.currentLegProgress.upComingStep, markUpWithSSML: markUpWithSSML)!
            var text: String
            if alertLevel == .arrive {
                text = upComingStepInstruction
            } else {
                text = String.localizedStringWithFormat(NSLocalizedString("WITH_DISTANCE_UTTERANCE_FORMAT", value: "In %@, %@", comment: "Format for speech string; 1 = formatted distance; 2 = instruction"), escapeIfNecessary(maneuverVoiceDistanceFormatter.string(from: userDistance)), upComingStepInstruction)
            }
            
            return text
        }
        
        // If there is no `upComingStep`, there definitely should not be a followOnStep.
        // This should be caught above.
        let upComingInstruction = routeStepFormatter.string(for: routeProgress.currentLegProgress.upComingStep, markUpWithSSML: markUpWithSSML)!
        let stepDistance = routeProgress.currentLegProgress.upComingStep!.distance
        let currentInstruction = routeStepFormatter.string(for: routeProgress.currentLegProgress.currentStep, markUpWithSSML: markUpWithSSML)
        let step = routeProgress.currentLegProgress.currentStep
        var text: String
        
        // We only want to announce this special depature announcement once.
        // Once it has been announced, all subsequnt announcements will not have an alert level of low
        // since the user will be approaching the maneuver location.
        if routeProgress.currentLegProgress.currentStep.maneuverType == .depart && alertLevel == .depart {
            if userDistance < RouteControllerMinimumDistanceForHighAlert {
                text = String.localizedStringWithFormat(NSLocalizedString("LINKED_WITH_DISTANCE_UTTERANCE_FORMAT", value: "%@, then in %@, %@", comment: "Format for speech string; 1 = current instruction; 2 = formatted distance to the following linked instruction; 3 = that linked instruction"), currentInstruction!, escapeIfNecessary(maneuverVoiceDistanceFormatter.string(from: userDistance)), upComingInstruction)
            } else {
                text = String.localizedStringWithFormat(NSLocalizedString("CONTINUE", value: "Continue on %@ for %@", comment: "Format for speech string; 1 = way name; 2 = distance"), escapeIfNecessary(localizeRoadDescription(step)), escapeIfNecessary(maneuverVoiceDistanceFormatter.string(from: userDistance)))
            }
        } else if routeProgress.currentLegProgress.currentStep.distance > 2_000 {
            text = String.localizedStringWithFormat(NSLocalizedString("CONTINUE", value: "Continue on %@ for %@", comment: "Format for speech string; 1 = way name; 2 = distance"), escapeIfNecessary(localizeRoadDescription(step)), escapeIfNecessary(maneuverVoiceDistanceFormatter.string(from: userDistance)))
        } else if alertLevel == .high && stepDistance < RouteControllerMinimumDistanceForHighAlert {
            text = String.localizedStringWithFormat(NSLocalizedString("LINKED_UTTERANCE_FORMAT", value: "%@, then %@", comment: "Format for speech string; 1 = current instruction; 2 = the following linked instruction"), upComingInstruction, followOnInstruction)
        } else if alertLevel != .high {
            text = String.localizedStringWithFormat(NSLocalizedString("WITH_DISTANCE_UTTERANCE_FORMAT", value: "In %@, %@", comment: "Format for speech string; 1 = formatted distance; 2 = instruction"), escapeIfNecessary(maneuverVoiceDistanceFormatter.string(from: userDistance)), upComingInstruction)
        } else {
            text = upComingInstruction
        }
        
        return text
    }
    
    func localizeRoadDescription(_ step: RouteStep) -> String {
        var road = ""
        if let name = step.names?.first {
            if let code = step.codes?.first {
                road = String.localizedStringWithFormat(NSLocalizedString("NAME_AND_REF", value: "%@ (%@)", comment: "Format for speech string; 1 = way name; 2 = way route number"), name, code)
            } else {
                road = name
            }
        } else if let code = step.codes?.first {
            road = code
        }
        return road
    }
    
    func speakWithPolly(_ text: String) {
        assert(!text.isEmpty)
        
        speechSynth.delegate = self
        let input = AWSPollySynthesizeSpeechURLBuilderRequest()
        input.textType = .ssml
        input.outputFormat = .mp3
        
        let langs = Locale.preferredLanguages.first!.components(separatedBy: "-")
        let langCode = langs[0]
        var countryCode = ""
        if langs.count > 1 {
            countryCode = langs[1]
        }
        
        if let voiceId = globalVoiceId {
            input.voiceId = voiceId
        } else {
            switch (langCode, countryCode) {
            case ("de", _):
                input.voiceId = .marlene
            case ("en", "GB"), ("en", "CA"):
                input.voiceId = .joanna
            case ("en", "AU"):
                input.voiceId = .nicole
            case ("en", "IN"):
                input.voiceId = .raveena
            case ("en", _):
                input.voiceId = .joanna
            case ("fr", _):
                input.voiceId = .celine
            case ("nl", _):
                input.voiceId = .lotte
            default:
                input.voiceId = .joanna
                return
            }
        }
        
        input.text = "<speak><prosody volume='\(instructionVoiceVolume)' rate='\(instructionVoiceSpeedRate)'>\(text)</prosody></speak>"
        
        let builder = AWSPollySynthesizeSpeechURLBuilder.default().getPreSignedURL(input)
        builder.continueWith { [weak self] (awsTask: AWSTask<NSURL>) -> Any? in
            guard let strongSelf = self else {
                return nil
            }
            
            guard awsTask.error == nil else {
                strongSelf.speakFallBack(strongSelf.fallbackText, error: awsTask.error!.localizedDescription)
                return nil
            }
            
            guard let url = awsTask.result else {
                strongSelf.speakFallBack(strongSelf.fallbackText, error: "No polly response")
                return nil
            }
            
            if let currentItem = strongSelf.audioPlayer.currentItem {
                currentItem.removeObserver(strongSelf, forKeyPath: "status")
            }
            
            let playerItem = AVPlayerItem(url: url as URL)
            strongSelf.audioPlayer.replaceCurrentItem(with: playerItem)
            
            strongSelf.audioPlayer.currentItem?.addObserver(strongSelf, forKeyPath: "status", options: NSKeyValueObservingOptions(), context: nil)
            
            return nil
        }
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            do {
                try duckAudio()
            } catch {
                print(error)
            }
            
            if let error = audioPlayer.currentItem?.error {
                self.speakFallBack(fallbackText, error: error.localizedDescription)
            } else {
                audioPlayer.play()
            }
        }
    }
    
    
    func speakFallBack(_ text: String, error: String? = nil) {
        // Note why it failed
        if let error = error {
            print(error)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        
        // change the rate of speech for iOS 8
        if !ProcessInfo().isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 9, minorVersion: 0, patchVersion: 0)) {
            utterance.rate = AVSpeechUtteranceMinimumSpeechRate + AVSpeechUtteranceDefaultSpeechRate / 5.0
        }
        
        // Only localized languages will have a proper fallback voice
        utterance.voice = AVSpeechSynthesisVoice(language: Bundle.main.preferredLocalizations.first)
        
        speechSynth.speak(utterance)
    }
}
