import Foundation

public enum PetAnimation: String, Equatable { case idle, happy, sick, sleeping }
public enum PetOverlay: String, Equatable { case none, focus, sweat }

public struct PetVisual: Equatable {
    public let stage: String
    public let animation: PetAnimation
    public let overlay: PetOverlay
    public init(stage: String, animation: PetAnimation, overlay: PetOverlay) {
        self.stage = stage
        self.animation = animation
        self.overlay = overlay
    }
}

public enum PetMood {
    public static func derive(pet: Pet, pressure: PressureTier) -> PetVisual {
        let stage = PixelSpeciesCatalog.stage(id: pet.species, xp: pet.xp)
        let overlay: PetOverlay
        switch pressure {
        case .calm: overlay = .none
        case .busy: overlay = .focus
        case .stressed: overlay = .sweat
        }

        let animation: PetAnimation
        if pet.hibernationSince != nil {
            animation = .sleeping
        } else if DeathWindow.isLowDay(
            pet: pet,
            threshold: ConfigYAML.defaults.thresholds.deathStatLow,
            requiredCount: ConfigYAML.defaults.thresholds.deathLowStatsRequired
        ) {
            animation = .sick
        } else {
            animation = .idle
        }
        return PetVisual(stage: stage, animation: animation, overlay: overlay)
    }
}
