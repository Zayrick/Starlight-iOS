//
//  StreamTextField.swift
//  Starlight
//
//  An invisible text field that brings up the software keyboard and types
//  what's entered into it on the host, after VoidLink. It always holds a
//  placeholder character, so that deleting it can be told apart as
//  Backspace even with nothing typed.
//

#if os(iOS) || os(visionOS)
import UIKit

final class StreamTextField: UITextField, UITextFieldDelegate {
    /// A zero width space, which nothing types by accident.
    private static let placeholder = "\u{200B}"

    private let input: StreamInput
    /// The keyboard went away, for whatever reason.
    var onEnd: (() -> Void)?

    init(input: StreamInput) {
        self.input = input
        super.init(frame: .zero)
        // Typed as is, without the keyboard rewriting it on the host
        keyboardType = .default
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        textColor = .clear
        tintColor = .clear
        delegate = self
        text = Self.placeholder
        addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Suppresses the undo menu that comes with three finger gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    @objc private func textChanged() {
        // Waits for an input method, like Pinyin, to settle on the text
        guard markedTextRange == nil else { return }
        let text = text ?? ""
        if text.isEmpty {
            input.typeShortcut([.backspace])
        } else {
            input.type(text.replacingOccurrences(of: Self.placeholder, with: ""))
        }
        self.text = Self.placeholder
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        input.typeShortcut([.enter])
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onEnd?()
    }
}
#endif
