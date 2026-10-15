import SwiftUI

// Visual theme styling & colors
extension EntryKind {
    var themeColor: Color {
        switch self {
        case .expense: .red
        case .income: .teal
        case .transfer: .indigo
        case .refund: .orange
        }
    }
}

// Keep platform differences at the view boundary; validation stays in the domain.
enum LedgerKeyboard { case decimalPad, numberPad, numbersAndPunctuation, URL }

extension View {
    @ViewBuilder func ledgerKeyboard(_ kind: LedgerKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .decimalPad: keyboardType(.decimalPad)
        case .numberPad: keyboardType(.numberPad)
        case .numbersAndPunctuation: keyboardType(.numbersAndPunctuation)
        case .URL: keyboardType(.URL)
        }
        #else
        self
        #endif
    }

    @ViewBuilder func ledgerVerbatimInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func ledgerInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func ledgerSearchable(text: Binding<String>) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索备注、分类、金额")
        #else
        searchable(text: text, prompt: "搜索备注、分类、金额")
        #endif
    }

    @ViewBuilder func ledgerForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    @ViewBuilder func ledgerEditorSize() -> some View {
        #if os(macOS)
        frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 640)
        #else
        self
        #endif
    }
}
