import SwiftUI

/// Sheet allowing user to choose paper template type and paper tone.
public struct TemplatePickerSheet: View {
    @Binding public var selectedTemplate: PaperTemplateType
    @Binding public var selectedPaperColor: PaperColor
    public var onApplyToAllPages: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    public init(
        selectedTemplate: Binding<PaperTemplateType>,
        selectedPaperColor: Binding<PaperColor>,
        onApplyToAllPages: (() -> Void)? = nil
    ) {
        self._selectedTemplate = selectedTemplate
        self._selectedPaperColor = selectedPaperColor
        self.onApplyToAllPages = onApplyToAllPages
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Paper Color & Tone")) {
                    HStack(spacing: 16) {
                        ForEach(PaperColor.allCases) { color in
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(color.backgroundColor)
                                    .frame(height: 54)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(selectedPaperColor == color ? BrandTheme.brandPurple : Color.gray.opacity(0.3), lineWidth: selectedPaperColor == color ? 3 : 1)
                                    )
                                    .overlay(
                                        color == .dark ?
                                        Image(systemName: "moon.fill").foregroundColor(.white.opacity(0.4)).font(.caption) :
                                        nil
                                    )
                                
                                Text(color.rawValue)
                                    .font(.system(size: 11, weight: selectedPaperColor == color ? .bold : .regular))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPaperColor = color
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Paper Layout & Ruling")) {
                    ForEach(PaperTemplateType.allCases) { template in
                        HStack(spacing: 14) {
                            Image(systemName: template.iconName)
                                .font(.system(size: 20))
                                .foregroundColor(selectedTemplate == template ? BrandTheme.brandPurple : .secondary)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.rawValue)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(template.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedTemplate == template {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(BrandTheme.brandPurple)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTemplate = template
                        }
                    }
                }
                
                if let applyAll = onApplyToAllPages {
                    Section {
                        Button {
                            applyAll()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Apply Template to All Pages")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(BrandTheme.brandPurple)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Paper Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(BrandTheme.brandPurple)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
