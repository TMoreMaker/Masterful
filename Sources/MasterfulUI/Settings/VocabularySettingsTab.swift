import MasterfulKit
import Persistence
import SwiftUI

struct VocabularySettingsTab: View {
    @Bindable var services: UIServices
    @State private var draft = ""
    @State private var terms: [VocabularyTerm] = []
    @State private var rejectedDuplicate = false

    var body: some View {
        SettingsPane {
            Card {
                SectionHeader(
                    "Custom vocabulary",
                    subtitle: "Names, products and jargon. These bias the recogniser directly and fix their own capitalisation afterwards, so “SwiftUI” never comes back as “Swift UI”."
                )

                HStack(spacing: Token.Space.sm) {
                    TextField("Add a word or phrase", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if rejectedDuplicate {
                    Text("Already in your vocabulary.")
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                if terms.isEmpty {
                    Text("Nothing yet. Add the words the recogniser keeps getting wrong.")
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(terms, id: \.persistentModelID) { term in
                        HStack {
                            Text(term.term).font(Typeface.rowTitle)
                            Spacer()
                            Button {
                                services.historyStore.removeVocabulary(term)
                                reload()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        if term.persistentModelID != terms.last?.persistentModelID {
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func add() {
        let added = services.historyStore.addVocabulary(draft)
        rejectedDuplicate = !added
        if added {
            draft = ""
            reload()
            // The recogniser reads its bias list when a session begins, so push
            // the change through rather than waiting for the next relaunch.
            services.onSettingsChanged()
        }
    }

    private func reload() {
        terms = services.historyStore.vocabulary()
    }
}
