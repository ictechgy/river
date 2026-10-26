/// The selection's first read is distinct from a confirmed empty repository.
enum DiffSelectionPresentation: Equatable {
  case validationFailure, pendingWorktree, initialLoading, review

  init(repositoryAvailable: Bool, diffAvailable: Bool, validatingSelection: Bool,
       selectionCheckFailed: Bool, pendingWorktree: Bool, isViewingStash: Bool) {
    if !isViewingStash && selectionCheckFailed && (!repositoryAvailable || !diffAvailable) {
      self = .validationFailure
    } else if !isViewingStash && pendingWorktree {
      self = .pendingWorktree
    } else if !isViewingStash && !repositoryAvailable && validatingSelection && !selectionCheckFailed {
      self = .initialLoading
    } else {
      self = .review
    }
  }

  @MainActor init(_ store: WorkbenchStore) {
    self.init(repositoryAvailable: store.repository != nil, diffAvailable: store.diff != nil,
      validatingSelection: store.validatingSelection, selectionCheckFailed: store.selectionCheckFailed,
      pendingWorktree: store.pendingWorktree, isViewingStash: store.isViewingStash)
  }
}
