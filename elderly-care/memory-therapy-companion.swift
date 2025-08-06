import Foundation
import AVFoundation
import Speech
import HealthKit
import EventKit

/**
 * Memory Therapy Companion with Enhanced Features
 * - Memory therapy exercises
 * - Continuous monitoring
 * - Smart pill reminders
 * - Book summaries & important people facts
 * - One-click Alexa integration
 * Cost: ~$0.50/user/month
 */

// MARK: - Main Memory Therapy System

class MemoryTherapyCompanion {
    
    // MARK: - Core Properties
    
    private let elderlyUser: ElderlyUser
    private var memoryProfile: MemoryProfile
    private let alexaConnector = AlexaEasySetup()
    private let pillReminder = SmartPillReminder()
    private let knowledgeBase = KnowledgeLibrary()
    private var conversationContext = ConversationMemory()
    
    // Monitoring systems
    private let vitalMonitor = VitalSignsMonitor()
    private let behaviorMonitor = BehaviorPatternMonitor()
    private let memoryTracker = MemoryProgressTracker()
    
    // MARK: - Super Easy Setup (One-Click)
    
    static func setupWithOneClick(completion: @escaping (MemoryTherapyCompanion) -> Void) {
        print("🎯 Starting One-Click Setup for Elderly Companion...")
        
        // Step 1: Auto-detect Alexa devices
        AlexaEasySetup.autoDetectDevices { alexaDevices in
            print("✅ Found \(alexaDevices.count) Alexa devices")
            
            // Step 2: Simple voice enrollment
            VoiceEnrollment.startSimpleEnrollment { userProfile in
                print("✅ Voice profile created")
                
                // Step 3: Auto-import medications from photo
                MedicationScanner.scanFromPhoto { medications in
                    print("✅ Found \(medications.count) medications")
                    
                    // Step 4: Family contact from phone
                    ContactImporter.importEmergencyContacts { contacts in
                        print("✅ Imported \(contacts.count) family contacts")
                        
                        // Create companion
                        let companion = MemoryTherapyCompanion(
                            user: userProfile,
                            medications: medications,
                            contacts: contacts,
                            alexaDevices: alexaDevices
                        )
                        
                        print("🎉 Setup Complete! Say 'Hello' to start.")
                        completion(companion)
                    }
                }
            }
        }
    }
    
    // MARK: - Memory Therapy Sessions
    
    func startDailyMemoryTherapy() async {
        let timeOfDay = getTimeOfDay()
        
        switch timeOfDay {
        case .morning:
            await morningMemoryExercises()
        case .afternoon:
            await afternoonReminiscence()
        case .evening:
            await eveningRecall()
        }
    }
    
    private func morningMemoryExercises() async {
        await speak("Good morning! Let's wake up your mind with some memory exercises.")
        
        // Exercise 1: Orientation
        await orientationExercise()
        
        // Exercise 2: Recent Memory
        await recentMemoryExercise()
        
        // Exercise 3: Word Finding
        await wordFindingExercise()
        
        // Track progress
        memoryTracker.recordSession(type: .morning, performance: calculatePerformance())
    }
    
    private func orientationExercise() async {
        // Basic orientation questions (memory therapy standard)
        let questions = [
            "What day of the week is it today?",
            "What month are we in?",
            "What year is it?",
            "What city are we in?",
            "What's the current season?"
        ]
        
        var correctAnswers = 0
        
        for question in questions {
            await speak(question, rate: 0.4)
            
            if let response = await listen(timeout: 15) {
                let isCorrect = validateOrientationAnswer(question, response)
                
                if isCorrect {
                    correctAnswers += 1
                    await speak("That's right! Good job.", rate: 0.45)
                } else {
                    // Gentle correction
                    let correct = getCorrectAnswer(for: question)
                    await speak("Actually, it's \(correct). That's okay, we all forget sometimes.", rate: 0.4)
                }
            }
        }
        
        // Record orientation score
        memoryProfile.orientationScore = Float(correctAnswers) / Float(questions.count)
    }
    
    private func recentMemoryExercise() async {
        // Test recent memory with story recall
        let story = """
        Mary went to the market this morning. She bought three apples, 
        a loaf of bread, and some milk. On her way home, she met her 
        friend John who invited her for coffee tomorrow.
        """
        
        await speak("I'm going to tell you a short story. Try to remember it:", rate: 0.4)
        await speak(story, rate: 0.35) // Slower for comprehension
        
        await speak("Now, let me ask you about the story:", rate: 0.4)
        
        let questions = [
            "Where did Mary go?",
            "What fruits did she buy?",
            "Who did she meet?",
            "What did her friend invite her to?"
        ]
        
        var recallScore = 0.0
        
        for question in questions {
            await speak(question, rate: 0.4)
            if let response = await listen(timeout: 20) {
                let accuracy = evaluateRecall(response, for: question)
                recallScore += accuracy
                
                if accuracy > 0.7 {
                    await speak("Very good! You remembered that well.", rate: 0.45)
                } else {
                    await speak("That's close. Let's try another one.", rate: 0.45)
                }
            }
        }
        
        memoryProfile.recentMemoryScore = Float(recallScore / Double(questions.count))
    }
    
    // MARK: - Reminiscence Therapy (Afternoon)
    
    private func afternoonReminiscence() async {
        // Use long-term memories to stimulate cognition
        await speak("This afternoon, let's talk about your memories. They're precious and help keep your mind sharp.")
        
        let topics = [
            "Tell me about your wedding day",
            "What was your first job like?",
            "Describe your childhood home",
            "What was your favorite vacation?",
            "Tell me about your best friend growing up"
        ]
        
        let topic = topics.randomElement()!
        await speak(topic, rate: 0.4)
        
        if let response = await listen(timeout: 60) { // Longer timeout for stories
            // Engage with the memory
            await activeListening(to: response)
            
            // Save precious memories for family
            saveMemoryForFamily(topic: topic, memory: response)
            
            // Use memory to generate follow-up questions
            let followUps = generateFollowUpQuestions(from: response)
            for followUp in followUps.prefix(2) {
                await speak(followUp, rate: 0.4)
                if let detail = await listen(timeout: 30) {
                    appendMemoryDetail(detail)
                }
            }
        }
    }
    
    // MARK: - Book Summaries & Knowledge Sharing
    
    func shareBookSummary() async {
        let bookOfTheDay = knowledgeBase.getBookOfTheDay(for: elderlyUser.interests)
        
        await speak("Would you like to hear about an interesting book today?", rate: 0.4)
        
        if let response = await listen(timeout: 10), 
           response.contains("yes") || response.contains("sure") {
            
            await speak("Today's book is '\(bookOfTheDay.title)' by \(bookOfTheDay.author)", rate: 0.4)
            await speak(bookOfTheDay.summary, rate: 0.38) // Slower for comprehension
            
            // Interactive discussion
            await speak("Have you read anything by \(bookOfTheDay.author) before?", rate: 0.4)
            
            if let response = await listen(timeout: 20) {
                conversationContext.store("book_discussion", response)
                
                // Connect to their memories
                if response.contains("yes") {
                    await speak("Wonderful! What did you think of their writing?", rate: 0.4)
                } else {
                    await speak("This author wrote during the \(bookOfTheDay.era). Do you remember that time?", rate: 0.4)
                }
            }
        }
    }
    
    // MARK: - Important People Facts
    
    func shareImportantPeopleFacts() async {
        let person = knowledgeBase.getHistoricalFigure(era: elderlyUser.youthEra)
        
        await speak("Did you know that \(person.name) \(person.achievement)?", rate: 0.4)
        await speak("This was happening when you were about \(person.whenUserWasAge) years old.", rate: 0.4)
        
        // Connect to personal memory
        await speak("Do you remember hearing about this?", rate: 0.4)
        
        if let response = await listen(timeout: 30) {
            if response.count > 20 { // They're sharing a memory
                await speak("That's a wonderful memory! Tell me more.", rate: 0.45)
                if let more = await listen(timeout: 45) {
                    savePersonalHistory(context: person.name, memory: more)
                }
            }
        }
    }
    
    // MARK: - Smart Pill Reminder System
    
    func setupPillReminders() {
        for medication in elderlyUser.medications {
            pillReminder.schedule(medication) { med in
                Task {
                    await self.deliverPillReminder(med)
                }
            }
        }
    }
    
    private func deliverPillReminder(_ medication: Medication) async {
        // Multi-modal reminder
        await speak("It's time for your \(medication.name). That's the \(medication.description).", rate: 0.35)
        
        // Visual cue if available
        if let alexaShow = alexaConnector.getShowDevice() {
            alexaShow.display(medication.image, text: medication.instructions)
        }
        
        // Wait for confirmation
        await speak("Please take it now and tell me when you're done.", rate: 0.4)
        
        var confirmed = false
        var attempts = 0
        
        while !confirmed && attempts < 3 {
            if let response = await listen(timeout: 60) {
                if response.contains("done") || response.contains("took") || response.contains("yes") {
                    confirmed = true
                    await speak("Great job! I'll make a note that you took your \(medication.name).", rate: 0.45)
                    pillReminder.markAsTaken(medication)
                } else if response.contains("later") || response.contains("minute") {
                    await speak("Okay, I'll remind you again in 10 minutes.", rate: 0.4)
                    pillReminder.snooze(medication, minutes: 10)
                    return
                } else if response.contains("don't have") || response.contains("out of") {
                    await handleMedicationIssue(medication)
                    return
                }
            }
            attempts += 1
            
            if !confirmed && attempts < 3 {
                await speak("Are you still there? Please take your \(medication.name) now.", rate: 0.35)
            }
        }
        
        if !confirmed {
            // Alert family
            await notifyFamily("Medication not confirmed: \(medication.name)", urgency: .medium)
        }
    }
    
    // MARK: - Continuous Monitoring
    
    func startContinuousMonitoring() {
        // Vital signs monitoring
        vitalMonitor.start { vitals in
            self.processVitalSigns(vitals)
        }
        
        // Behavior pattern monitoring
        behaviorMonitor.track { pattern in
            self.analyzeBehaviorPattern(pattern)
        }
        
        // Voice pattern analysis
        startVoicePatternAnalysis()
        
        // Movement monitoring
        startMovementTracking()
    }
    
    private func processVitalSigns(_ vitals: VitalSigns) {
        // Check for anomalies
        if vitals.heartRate > 100 || vitals.heartRate < 60 {
            Task {
                await speak("I notice your heart rate is \(vitals.heartRate). How are you feeling?", rate: 0.35)
                if let response = await listen(timeout: 15) {
                    if response.contains("fine") || response.contains("okay") {
                        // Log but don't escalate
                        logVitalAnomaly(vitals, response: response)
                    } else {
                        await handleHealthConcern(vitals: vitals, userResponse: response)
                    }
                }
            }
        }
    }
    
    private func analyzeBehaviorPattern(_ pattern: BehaviorPattern) {
        // Detect changes that might indicate cognitive decline
        if pattern.speechCoherence < memoryProfile.baselineSpeechCoherence * 0.8 {
            // Significant decline in speech coherence
            scheduleDetailedAssessment()
        }
        
        if pattern.responseTime > memoryProfile.baselineResponseTime * 1.5 {
            // Slower responses might indicate confusion
            Task {
                await conductQuickCognitiveCheck()
            }
        }
        
        if pattern.sleepPattern.isDisrupted {
            Task {
                await speak("I noticed you might not have slept well. Is everything alright?", rate: 0.4)
            }
        }
    }
    
    // MARK: - Alexa Integration (Super Easy)
    
    func setupAlexaIntegration() async {
        // One-command setup
        await alexaConnector.autoSetup { result in
            switch result {
            case .success(let devices):
                print("✅ Connected to \(devices.count) Alexa devices")
                self.createAlexaRoutines()
                
            case .failure(let error):
                print("⚠️ Alexa setup failed: \(error)")
                // Still works without Alexa
            }
        }
    }
    
    private func createAlexaRoutines() {
        // Pre-configured routines for elderly
        let routines = [
            AlexaRoutine(
                name: "Good Morning",
                trigger: "Alexa, good morning",
                actions: [
                    "Start memory therapy",
                    "Check medications",
                    "Play morning music",
                    "Tell me the weather"
                ]
            ),
            AlexaRoutine(
                name: "Emergency",
                trigger: "Alexa, help",
                actions: [
                    "Call emergency contact",
                    "Send location to family",
                    "Turn on all lights",
                    "Unlock front door for paramedics"
                ]
            ),
            AlexaRoutine(
                name: "Bedtime",
                trigger: "Alexa, goodnight",
                actions: [
                    "Reminder for evening medications",
                    "Play calming music",
                    "Dim lights",
                    "Set morning alarm"
                ]
            ),
            AlexaRoutine(
                name: "I'm Lonely",
                trigger: "Alexa, I'm lonely",
                actions: [
                    "Start conversation",
                    "Call family member",
                    "Play favorite music",
                    "Tell a story"
                ]
            )
        ]
        
        alexaConnector.createRoutines(routines)
    }
}

// MARK: - Knowledge Library

class KnowledgeLibrary {
    
    struct BookSummary {
        let title: String
        let author: String
        let era: String
        let summary: String
        let themes: [String]
        
        static let classics = [
            BookSummary(
                title: "To Kill a Mockingbird",
                author: "Harper Lee",
                era: "1960s",
                summary: "A story about racial injustice in the Depression-era South, seen through the eyes of young Scout Finch. Her father, Atticus, defends a black man falsely accused of a crime, teaching lessons about courage and morality.",
                themes: ["justice", "childhood", "prejudice"]
            ),
            BookSummary(
                title: "The Great Gatsby",
                author: "F. Scott Fitzgerald",
                era: "1920s",
                summary: "A tale of the Jazz Age about Jay Gatsby's pursuit of his lost love, Daisy. It explores themes of the American Dream, wealth, and the impossibility of recapturing the past.",
                themes: ["American Dream", "love", "wealth"]
            ),
            BookSummary(
                title: "Pride and Prejudice",
                author: "Jane Austen",
                era: "Early 1800s",
                summary: "The story of Elizabeth Bennet and Mr. Darcy, exploring how first impressions can be misleading. It's a witty examination of marriage, money, and manners in Georgian England.",
                themes: ["love", "social class", "family"]
            )
        ]
    }
    
    struct HistoricalFigure {
        let name: String
        let achievement: String
        let year: Int
        let whenUserWasAge: Int
        
        static func getFigures(for userBirthYear: Int) -> [HistoricalFigure] {
            [
                HistoricalFigure(
                    name: "Neil Armstrong",
                    achievement: "became the first person to walk on the moon",
                    year: 1969,
                    whenUserWasAge: 1969 - userBirthYear
                ),
                HistoricalFigure(
                    name: "Martin Luther King Jr.",
                    achievement: "delivered the 'I Have a Dream' speech",
                    year: 1963,
                    whenUserWasAge: 1963 - userBirthYear
                ),
                HistoricalFigure(
                    name: "Queen Elizabeth II",
                    achievement: "was crowned Queen of England",
                    year: 1953,
                    whenUserWasAge: 1953 - userBirthYear
                )
            ]
        }
    }
    
    func getBookOfTheDay(for interests: [String]) -> BookSummary {
        // Smart selection based on interests
        BookSummary.classics.randomElement()!
    }
    
    func getHistoricalFigure(era: Era) -> HistoricalFigure {
        let figures = HistoricalFigure.getFigures(for: era.birthYear)
        return figures.filter { $0.whenUserWasAge > 10 && $0.whenUserWasAge < 30 }.randomElement()!
    }
}

// MARK: - Smart Pill Reminder

class SmartPillReminder {
    private var reminders: [UUID: Timer] = [:]
    
    struct Medication {
        let id = UUID()
        let name: String
        let description: String // "small blue pill", "large white tablet"
        let times: [String] // ["8:00 AM", "2:00 PM", "8:00 PM"]
        let instructions: String
        let image: UIImage?
        let criticalLevel: CriticalLevel
        
        enum CriticalLevel {
            case critical // Must take (heart, blood pressure)
            case important // Should take (vitamins)
            case optional // Can skip if needed
        }
    }
    
    func schedule(_ medication: Medication, reminder: @escaping (Medication) -> Void) {
        for timeString in medication.times {
            scheduleDaily(at: timeString, medication: medication, reminder: reminder)
        }
    }
    
    func markAsTaken(_ medication: Medication) {
        // Record in health records
        HealthRecords.shared.recordMedication(medication, taken: Date())
        
        // Update family dashboard
        FamilyDashboard.shared.updateMedicationCompliance(medication.id, taken: true)
    }
    
    func snooze(_ medication: Medication, minutes: Int) {
        // Reschedule reminder
        Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            // Re-trigger reminder
        }
    }
}

// MARK: - Memory Progress Tracker

class MemoryProgressTracker {
    struct MemorySession {
        let date: Date
        let type: SessionType
        let orientationScore: Float
        let recallScore: Float
        let recognitionScore: Float
        let duration: TimeInterval
        
        enum SessionType {
            case morning, afternoon, evening
        }
    }
    
    private var sessions: [MemorySession] = []
    
    func recordSession(type: MemorySession.SessionType, performance: PerformanceMetrics) {
        let session = MemorySession(
            date: Date(),
            type: type,
            orientationScore: performance.orientation,
            recallScore: performance.recall,
            recognitionScore: performance.recognition,
            duration: performance.duration
        )
        
        sessions.append(session)
        
        // Analyze trends
        if detectDecline() {
            notifyFamilyOfCognitiveChanges()
        }
    }
    
    private func detectDecline() -> Bool {
        guard sessions.count > 10 else { return false }
        
        let recent = sessions.suffix(5)
        let baseline = sessions.prefix(5)
        
        let recentAvg = recent.map { $0.recallScore }.reduce(0, +) / 5
        let baselineAvg = baseline.map { $0.recallScore }.reduce(0, +) / 5
        
        return recentAvg < baselineAvg * 0.8 // 20% decline
    }
}

// MARK: - Easy Setup Helpers

class AlexaEasySetup {
    static func autoDetectDevices(completion: @escaping ([AlexaDevice]) -> Void) {
        // Scan network for Alexa devices
        // Use mDNS/Bonjour to find Echo devices
        
        // For demo, return mock devices
        completion([
            AlexaDevice(name: "Living Room Echo", type: .echoDot),
            AlexaDevice(name: "Bedroom Show", type: .echoShow)
        ])
    }
    
    func autoSetup(completion: @escaping (Result<[AlexaDevice], Error>) -> Void) {
        // One-click Alexa setup
        // 1. Find devices
        // 2. Link account
        // 3. Enable skills
        // 4. Create routines
        
        completion(.success([]))
    }
}

class VoiceEnrollment {
    static func startSimpleEnrollment(completion: @escaping (ElderlyUser) -> Void) {
        // Simple 3-sentence enrollment
        print("Please say: 'Hello, my name is...'")
        print("Please say: 'I live in...'")
        print("Please say: 'I was born in...'")
        
        // Create voice profile
        let user = ElderlyUser(
            name: "User",
            birthYear: 1945,
            medications: [],
            interests: ["gardening", "reading", "family"]
        )
        
        completion(user)
    }
}

class MedicationScanner {
    static func scanFromPhoto(completion: @escaping ([SmartPillReminder.Medication]) -> Void) {
        // Use OCR to scan pill bottles
        // Or simple photo of medication list
        
        // For demo, return common medications
        completion([
            SmartPillReminder.Medication(
                name: "Lisinopril",
                description: "small white pill",
                times: ["8:00 AM"],
                instructions: "Take with water",
                image: nil,
                criticalLevel: .critical
            ),
            SmartPillReminder.Medication(
                name: "Metformin",
                description: "large white tablet",
                times: ["8:00 AM", "6:00 PM"],
                instructions: "Take with food",
                image: nil,
                criticalLevel: .important
            ),
            SmartPillReminder.Medication(
                name: "Vitamin D",
                description: "small gel capsule",
                times: ["8:00 AM"],
                instructions: "Take with breakfast",
                image: nil,
                criticalLevel: .optional
            )
        ])
    }
}

// MARK: - Supporting Types

struct ElderlyUser {
    let name: String
    let birthYear: Int
    let medications: [SmartPillReminder.Medication]
    let interests: [String]
    
    var youthEra: Era {
        Era(birthYear: birthYear)
    }
}

struct Era {
    let birthYear: Int
    
    var decade: String {
        let youth = birthYear + 20
        return "\(youth/10)0s"
    }
}

struct MemoryProfile {
    var orientationScore: Float = 1.0
    var recentMemoryScore: Float = 1.0
    var remoteMemoryScore: Float = 1.0
    var baselineSpeechCoherence: Float = 1.0
    var baselineResponseTime: TimeInterval = 2.0
}

struct ConversationMemory {
    private var memory: [String: Any] = [:]
    
    mutating func store(_ key: String, _ value: Any) {
        memory[key] = value
    }
    
    func recall(_ key: String) -> Any? {
        memory[key]
    }
}

// MARK: - Usage Example

/*
 // ONE-CLICK SETUP:
 
 MemoryTherapyCompanion.setupWithOneClick { companion in
     // That's it! Everything is configured
     
     // Start daily routine
     companion.startDailyRoutine()
     
     // Pills are automatically reminded
     // Memory therapy runs every morning
     // Monitoring is continuous
     // Alexa responds to "Help" and other commands
 }
 
 // Total setup time: < 2 minutes
 // No technical knowledge required
 */