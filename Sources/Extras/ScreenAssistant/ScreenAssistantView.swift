//
//  ScreenAssistantView.swift
//  FunNotch
//
//  What the screen assistant's panel shows: the captured fragment, a question
//  field with a few quick questions, and the answer as it streams in. Plain
//  SwiftUI with no timers or observers of its own; it exists only while the
//  panel does.
//

import SwiftUI

struct ScreenAssistantView: View {
    @ObservedObject var session: ScreenAssistantSession
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    private struct QuickQuestion: Identifiable {
        let title: String
        let prompt: String
        var id: String { title }
    }

    private static let quickQuestions = [
        QuickQuestion(title: "Wyjaśnij", prompt: "Wyjaśnij, co jest na obrazie."),
        QuickQuestion(title: "Przepisz tekst", prompt: "Przepisz dokładnie cały tekst widoczny na obrazie."),
        QuickQuestion(title: "Przetłumacz na polski", prompt: "Przetłumacz tekst widoczny na obrazie na polski."),
        QuickQuestion(title: "Streść", prompt: "Streść zawartość obrazu."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            thumbnail
            if session.showsPermissionHint {
                Text("Jeśli zrzut pokazuje tylko tapetę, zezwól Fun Notch na nagrywanie ekranu w Ustawieniach systemowych → Prywatność i ochrona.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            quickButtons
            questionField
            if !session.turns.isEmpty {
                conversation
                footer
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: onClose)
        .onAppear {
            fieldFocused = true
            // The panel is made key right after the view appears; asking once
            // more lets the focus land once the window is ready for it.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: session.isRunning) { _, running in
            if !running { fieldFocused = true }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Label("Asystent ekranu", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(NotchPressStyle())
            .notchControl(in: Circle())
            .help("Zamknij (Esc)")
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = session.thumbnail {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var quickButtons: some View {
        HStack(spacing: 6) {
            ForEach(Self.quickQuestions) { quick in
                Button {
                    session.ask(quick.prompt)
                } label: {
                    Text(quick.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(NotchPressStyle())
                .notchControl(in: Capsule(), resting: true)
                .disabled(session.isRunning)
            }
        }
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            TextField("O co chcesz zapytać?", text: $session.question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit { session.ask(session.question) }
            Button {
                session.ask(session.question)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSend ? Color.white : Color.white.opacity(0.24))
            }
            .buttonStyle(NotchPressStyle())
            .disabled(!canSend)
            .help("Wyślij (Return)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var canSend: Bool {
        !session.isRunning && !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.turns) { turn in
                        turnView(turn, isLatest: turn.id == session.turns.last?.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: session.turns.last?.answer.count) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }

    private func turnView(_ turn: ScreenAssistantSession.Turn, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textSelection(.enabled)
            if !turn.answer.isEmpty {
                Text(turn.answer)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLatest, session.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Czekam na odpowiedź…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if let failure = turn.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if session.isRunning {
                Button {
                    session.cancel()
                } label: {
                    footerLabel("Anuluj", symbol: "stop.fill")
                }
                .buttonStyle(NotchPressStyle())
                .notchControl(in: Capsule(), resting: true)
            } else if session.canCopy {
                Button {
                    session.copyAnswer()
                } label: {
                    footerLabel(session.copied ? "Skopiowano" : "Kopiuj odpowiedź",
                                symbol: session.copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(NotchPressStyle())
                .notchControl(in: Capsule(), resting: true)
            }
            Spacer()
        }
        .frame(minHeight: 26)
    }

    private func footerLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}
