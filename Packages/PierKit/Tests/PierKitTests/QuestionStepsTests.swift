import Testing
@testable import PierKit

struct QuestionStepsTests {
    let qs = [
        Question(question: "Qual tema?", header: "Tema", options: [.init(label: "Tecnologia"), .init(label: "Livros")]),
        Question(question: "Quais formatos?", header: "Formato", multi: true, options: [.init(label: "Curtas"), .init(label: "Listas"), .init(label: "Emojis")]),
    ]

    @Test func onlyFormsWithStepsOrTicksNeedStepping() {
        #expect(QuestionSteps.needed(for: qs))
        #expect(QuestionSteps.needed(for: [qs[1]]))
        #expect(!QuestionSteps.needed(for: [qs[0]]))
    }

    @Test func aSingleChoiceMovesOnAndAMultipleChoiceTicksThenMovesOn() {
        var s = QuestionSteps(questions: qs)
        #expect(s.index == 0 && !s.isLast && !s.isComplete)
        let r1 = s.choose("Nada disso")
        #expect(!r1)
        let r2 = s.next()
        #expect(!r2)   // a single choice has no Next
        let r3 = s.choose("Livros")
        #expect(r3)
        #expect(s.index == 1 && s.isLast)
        let r4 = s.next()
        #expect(!r4)   // nothing ticked yet
        s.choose("Emojis"); s.choose("Curtas"); s.choose("Listas"); s.choose("Listas")
        #expect(s.ticked == ["Curtas", "Emojis"])   // in the options' order
        #expect(!s.isComplete)
        let r5 = s.next()
        #expect(r5)
        #expect(s.isComplete && s.current == nil)
        #expect(s.answers == [.pick("Livros"), .picks(["Curtas", "Emojis"])])
        #expect(QuestionHelpers.validate(s.answers, for: qs) == nil)
    }

    @Test func backTakesTheLastAnswerBackWithItsTicks() {
        var s = QuestionSteps(questions: qs)
        s.choose("Tecnologia"); s.choose("Listas"); s.next()
        s.back()
        #expect(s.index == 1 && s.ticked == ["Listas"] && !s.isComplete)
        s.back()
        #expect(s.index == 0 && s.ticked.isEmpty)
        s.back()
        #expect(s.index == 0)
    }
}
