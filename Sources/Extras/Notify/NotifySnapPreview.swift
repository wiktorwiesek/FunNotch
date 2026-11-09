//
//  NotifySnapPreview.swift
//  FunNotch
//
//  Preview-renderer jobs for the Powiadomienia tab and the window-snap zones,
//  filled with invented text that stresses the layout: very long titles and
//  bodies, empty bodies, a one-time code, emoji.
//

import SwiftUI

extension PreviewRenderer {
    static func appendNotifySnapJobs(to jobs: inout [(name: String, size: CGSize, dark: Bool, make: () -> AnyView)]) {
        let longText = String(repeating: "Bardzo długa treść powiadomienia bez końca, ", count: 40)
        let now = Date()
        func item(_ app: String, _ bundle: String?, _ title: String, _ body: String, _ ago: TimeInterval, code: String? = nil)
            -> MirroredNotification
        {
            MirroredNotification(
                id: UUID().uuidString, bundleIdentifier: bundle, appName: app,
                title: title, subtitle: "", body: body,
                date: now.addingTimeInterval(-ago), source: .banner, code: code
            )
        }

        jobs.append(("qa-notify-tab-full", CGSize(width: 640, height: 230), true, {
            NotifyCenter.shared.injectPreviewItems([
                item("Wiadomości", "com.apple.MobileSMS", "Anna", "Będę za dziesięć minut 🙂", 5),
                item("Slack", "com.tinyspeck.slackmacgap", "Jan Kowalski", "Zażółć gęślą jaźń — test polskich znaków", 120),
                item("Bank", nil, "Kod BLIK", "Twój kod weryfikacyjny: 123456", 300, code: "123456"),
                item("Mail", "com.apple.mail", longText, longText, 900),
                item("Przypomnienia", "com.apple.reminders", "Zadzwonić do dostawcy", "", 3600),
                item("Dysk", nil, "", "Tylko treść bez tytułu", 7200),
            ])
            return AnyView(
                NotificationsTabView()
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .frame(width: 640, height: 230)
                    .background(Color.black)
            )
        }))
        jobs.append(("qa-notify-tab-empty", CGSize(width: 640, height: 230), true, {
            NotifyCenter.shared.injectPreviewItems([])
            return AnyView(
                NotificationsTabView()
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .frame(width: 640, height: 230)
                    .background(Color.black)
            )
        }))
        for hovered in [WindowSnapZone.rightThird, .topLeft] {
            jobs.append(("qa-snap-overlay-\(hovered.rawValue)", CGSize(width: 580, height: 210), true, {
                let model = WindowSnapOverlayModel()
                model.hovered = hovered
                return AnyView(
                    WindowSnapOverlayView(model: model)
                        .padding(20)
                        .background(Color(white: 0.3))
                )
            }))
        }
        for dark in [false, true] {
            jobs.append(("qa-notify-settings-\(dark ? "dark" : "light")", CGSize(width: 760, height: 1000), dark, {
                AnyView(NotifyExtrasSettings().padding(24).frame(width: 760, alignment: .topLeading))
            }))
            jobs.append(("qa-snap-settings-\(dark ? "dark" : "light")", CGSize(width: 760, height: 620), dark, {
                AnyView(WindowSnapSettings().padding(24).frame(width: 760, alignment: .topLeading))
            }))
        }
    }
}
