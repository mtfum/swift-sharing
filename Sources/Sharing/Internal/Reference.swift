import Dependencies
import Foundation
import IdentifiedCollections
import PerceptionCore

#if canImport(Combine)
  import Combine
#endif

protocol Reference<Value>:
  AnyObject,
  CustomStringConvertible,
  Sendable,
  Perceptible
{
  associatedtype Value

  var id: ObjectIdentifier { get }
  var loadError: (any Error)? { get }
  var wrappedValue: Value { get }
  func load() throws
  func touch()
  #if canImport(Combine)
    var publisher: any Publisher<Value, Never> { get }
  #endif
}

protocol MutableReference<Value>: Reference, Equatable {
  var saveError: (any Error)? { get }
  var snapshot: Value? { get }
  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R
  func takeSnapshot(
    _ value: Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  )
  func save() throws
}

final class _BoxReference<Value>: MutableReference, Observable, Perceptible, @unchecked Sendable {
  private let _$perceptionRegistrar = PerceptionRegistrar(isPerceptionCheckingEnabled: false)
  private let lock = NSRecursiveLock()

  #if canImport(Combine)
    private var value: Value {
      willSet {
        subject.send(newValue)
      }
    }
    let subject = PassthroughRelay<Value>()

    var publisher: any Publisher<Value, Never> {
      subject.prepend(lock.withLock { value })
    }
  #else
    private var value: Value
  #endif

  init(wrappedValue: Value) {
    self.value = wrappedValue
  }

  var id: ObjectIdentifier { ObjectIdentifier(self) }

  var loadError: (any Error)? {
    nil
  }

  var saveError: (any Error)? {
    nil
  }

  var wrappedValue: Value {
    access(keyPath: \.value)
    return lock.withLock { value }
  }

  var snapshot: Value? {
    @Dependency(\.snapshots) var snapshots
    return snapshots[self]
  }

  func takeSnapshot(
    _ value: Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    @Dependency(\.snapshots) var snapshots
    snapshots.save(
      key: self,
      value: value,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  func load() {}

  func touch() {
    withMutation(keyPath: \.value) {}
  }

  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    try withMutation(keyPath: \.value) {
      try lock.withLock { try body(&value) }
    }
  }

  func save() {}

  static func == (lhs: _BoxReference, rhs: _BoxReference) -> Bool {
    lhs === rhs
  }

  func access<Member>(
    keyPath: KeyPath<_BoxReference, Member>,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    _$perceptionRegistrar.access(
      self,
      keyPath: keyPath,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  func withMutation<Member, MutationResult>(
    keyPath: _SendableKeyPath<_BoxReference, Member>,
    _ mutation: () throws -> MutationResult
  ) rethrows -> MutationResult {
    #if os(WASI)
      return try _$perceptionRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    #else
      if Thread.isMainThread {
        return try _$perceptionRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
      } else {
        DispatchQueue.main.async {
          self._$perceptionRegistrar.withMutation(of: self, keyPath: keyPath) {}
        }
        return try mutation()
      }
    #endif
  }

  var description: String {
    "value: \(String(reflecting: wrappedValue))"
  }
}

final class _PersistentReference<Key: SharedReaderKey>:
  Reference, Observable, Perceptible, @unchecked Sendable
{
  private let _$perceptionRegistrar = PerceptionRegistrar(isPerceptionCheckingEnabled: false)
  private let key: Key
  private let lock = NSRecursiveLock()

  #if canImport(Combine)
    private var value: Key.Value {
      willSet {
        subject.send(newValue)
      }
    }
    private let subject = PassthroughRelay<Value>()

    var publisher: any Publisher<Key.Value, Never> {
      subject.prepend(lock.withLock { value })
    }
  #else
    private var value: Key.Value
  #endif

  private var _didAccessLoadError = false
  private var _didAccessSaveError = false
  private var _loadError: (any Error)?
  private var _saveError: (any Error)?
  private var _referenceCount = 0
  private var subscription: SharedSubscription?

  init(key: Key, value initialValue: Key.Value) {
    self.key = key
    do {
      self.value = try key.load(initialValue: initialValue) ?? initialValue
    } catch {
      self._loadError = error
      self.value = initialValue
    }
    self.subscription = key.subscribe(initialValue: initialValue) { [weak self] result in
      guard let self else { return }
      switch result {
      case let .failure(error):
        loadError = error
      case let .success(newValue):
        loadError = nil
        wrappedValue = newValue ?? initialValue
      }
    }
  }

  var id: ObjectIdentifier { ObjectIdentifier(self) }

  var loadError: (any Error)? {
    get {
      access(keyPath: \._loadError)
      return lock.withLock {
        _didAccessLoadError = true
        return _loadError
      }
    }
    set {
      withMutation(keyPath: \._loadError) {
        lock.withLock {
          defer { _didAccessLoadError = false }
          _loadError = newValue
          if !_didAccessSaveError, let newValue {
            reportIssue(newValue)
          }
        }
      }
    }
  }

  var wrappedValue: Key.Value {
    get {
      access(keyPath: \.value)
      return lock.withLock { value }
    }
    set {
      withMutation(keyPath: \.value) {
        lock.withLock { value = newValue }
      }
    }
  }

  func load() throws {
    do {
      loadError = nil
      guard let newValue = try key.load(initialValue: nil)
      else {
        // TODO: Should we keep track of the initial value and reassign it here?
        return
      }
      wrappedValue = newValue
    } catch {
      loadError = error
    }
  }

  func touch() {
    withMutation(keyPath: \.value) {}
    // TODO: Is this needed?
    // withMutation(keyPath: \._loadError) {}
    // withMutation(keyPath: \._saveError) {}
  }

  func retain() {
    lock.withLock { _referenceCount += 1 }
  }

  func release() {
    let shouldRelease = lock.withLock {
      _referenceCount -= 1
      return _referenceCount <= 0
    }
    guard shouldRelease else { return }
    @Dependency(PersistentReferences.self) var persistentReferences
    persistentReferences.removeReference(forKey: key)
  }

  func access<Member>(
    keyPath: KeyPath<_PersistentReference, Member>,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    _$perceptionRegistrar.access(
      self,
      keyPath: keyPath,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  func withMutation<Member, MutationResult>(
    keyPath: _SendableKeyPath<_PersistentReference, Member>,
    _ mutation: () throws -> MutationResult
  ) rethrows -> MutationResult {
    #if os(WASI)
      return try _$perceptionRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    #else
      if Thread.isMainThread {
        return try _$perceptionRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
      } else {
        DispatchQueue.main.async {
          self._$perceptionRegistrar.withMutation(of: self, keyPath: keyPath) {}
        }
        return try mutation()
      }
    #endif
  }

  var description: String {
    String(reflecting: key)
  }
}

extension _PersistentReference: MutableReference, Equatable where Key: SharedKey {
  var saveError: (any Error)? {
    get {
      access(keyPath: \._saveError)
      return lock.withLock {
        _didAccessSaveError = true
        return _saveError
      }
    }
    set {
      withMutation(keyPath: \._saveError) {
        lock.withLock {
          defer { _didAccessSaveError = false }
          _saveError = newValue
          if !_didAccessSaveError, let newValue {
            reportIssue(newValue)
          }
        }
      }
    }
  }

  var snapshot: Key.Value? {
    @Dependency(\.snapshots) var snapshots
    return snapshots[self]
  }

  func takeSnapshot(
    _ value: Key.Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    @Dependency(\.snapshots) var snapshots
    snapshots.save(
      key: self,
      value: value,
      fileID: fileID,
      filePath: filePath,
      line: line,
      column: column
    )
  }

  func withLock<R>(_ body: (inout Key.Value) throws -> R) rethrows -> R {
    try withMutation(keyPath: \.value) {
      saveError = nil
      defer {
        do {
          try key.save(value, immediately: false)
          loadError = nil
        } catch {
          saveError = error
        }
      }
      return try lock.withLock {
        try body(&value)
      }
    }
  }

  func save() throws {
    saveError = nil
    try key.save(lock.withLock { value }, immediately: true)
    loadError = nil
  }

  static func == (lhs: _PersistentReference, rhs: _PersistentReference) -> Bool {
    lhs === rhs
  }
}

final class _ManagedReference<Key: SharedReaderKey>: Reference, Observable {
  private let base: _PersistentReference<Key>

  init(_ base: _PersistentReference<Key>) {
    base.retain()
    self.base = base
  }

  deinit {
    base.release()
  }

  var id: ObjectIdentifier {
    base.id
  }

  var loadError: (any Error)? {
    base.loadError
  }

  var wrappedValue: Key.Value {
    base.wrappedValue
  }

  func load() throws {
    try base.load()
  }

  func touch() {
    base.touch()
  }

  #if canImport(Combine)
    var publisher: any Publisher<Key.Value, Never> {
      base.publisher
    }
  #endif

  var description: String {
    base.description
  }
}

extension _ManagedReference: MutableReference, Equatable where Key: SharedKey {
  var saveError: (any Error)? {
    base.saveError
  }

  var snapshot: Key.Value? {
    base.snapshot
  }

  func takeSnapshot(
    _ value: Key.Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    base.takeSnapshot(value, fileID: fileID, filePath: filePath, line: line, column: column)
  }

  func withLock<R>(_ body: (inout Key.Value) throws -> R) rethrows -> R {
    try base.withLock(body)
  }

  func save() throws {
    try base.save()
  }

  static func == (lhs: _ManagedReference, rhs: _ManagedReference) -> Bool {
    lhs.base == rhs.base
  }
}

final class _AppendKeyPathReference<
  Base: Reference, Value, Path: KeyPath<Base.Value, Value> & Sendable
>: Reference, Observable {
  private let base: Base
  private let keyPath: Path

  init(base: Base, keyPath: Path) {
    self.base = base
    self.keyPath = keyPath
  }

  var id: ObjectIdentifier {
    base.id
  }

  var loadError: (any Error)? {
    base.loadError
  }

  var wrappedValue: Value {
    base.wrappedValue[keyPath: keyPath]
  }

  func load() throws {
    try base.load()
  }

  func touch() {
    base.touch()
  }

  #if canImport(Combine)
    var publisher: any Publisher<Value, Never> {
      func open(_ publisher: some Publisher<Base.Value, Never>) -> any Publisher<Value, Never> {
        publisher.map(keyPath)
      }
      return open(base.publisher)
    }
  #endif

  var description: String {
    "\(base.description)[dynamicMember: \(keyPath)]"
  }
}

extension _AppendKeyPathReference: MutableReference, Equatable
where Base: MutableReference, Path: WritableKeyPath<Base.Value, Value> {
  var saveError: (any Error)? {
    base.saveError
  }

  var snapshot: Value? {
    base.snapshot?[keyPath: keyPath]
  }

  func takeSnapshot(
    _ value: Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    var snapshot = base.snapshot ?? base.wrappedValue
    snapshot[keyPath: keyPath as WritableKeyPath] = value
    base.takeSnapshot(snapshot, fileID: fileID, filePath: filePath, line: line, column: column)
  }

  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    try base.withLock { try body(&$0[keyPath: keyPath as WritableKeyPath]) }
  }

  func save() throws {
    try base.save()
  }

  static func == (lhs: _AppendKeyPathReference, rhs: _AppendKeyPathReference) -> Bool {
    lhs.base == rhs.base && lhs.keyPath == rhs.keyPath
  }
}

final class _OptionalReference<Base: Reference<Value?>, Value>:
  Reference,
  Observable,
  @unchecked Sendable
{
  private let base: Base
  private var cachedValue: Value
  private let lock = NSRecursiveLock()

  init(base: Base, initialValue: Value) {
    self.base = base
    self.cachedValue = initialValue
  }

  var id: ObjectIdentifier {
    base.id
  }

  var loadError: (any Error)? {
    base.loadError
  }

  var wrappedValue: Value {
    guard let wrappedValue = base.wrappedValue else { return lock.withLock { cachedValue } }
    lock.withLock { cachedValue = wrappedValue }
    return wrappedValue
  }

  func load() throws {
    try base.load()
  }

  func touch() {
    base.touch()
  }

  #if canImport(Combine)
    var publisher: any Publisher<Value, Never> {
      func open(_ publisher: some Publisher<Value?, Never>) -> any Publisher<Value, Never> {
        publisher.compactMap { $0 }
      }
      return open(base.publisher)
    }
  #endif

  var description: String {
    "\(base.description)!"
  }
}

extension _OptionalReference: MutableReference, Equatable where Base: MutableReference {
  var saveError: (any Error)? {
    base.saveError
  }

  var snapshot: Value? {
    base.snapshot ?? nil
  }

  func takeSnapshot(
    _ value: Value,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    guard base.snapshot != nil else { return }
    base.takeSnapshot(value, fileID: fileID, filePath: filePath, line: line, column: column)
  }

  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    try base.withLock { value in
      guard var unwrapped = value else { return try lock.withLock { try body(&cachedValue) } }
      defer {
        value = unwrapped
        lock.withLock { cachedValue = unwrapped }
      }
      return try body(&unwrapped)
    }
  }

  func save() throws {
    try base.save()
  }

  static func == (lhs: _OptionalReference, rhs: _OptionalReference) -> Bool {
    lhs.base == rhs.base
  }
}

#if canImport(SwiftUI)
  protocol _CachedReferenceProtocol<Value>: AnyObject, Sendable {
    associatedtype Value
    var cachedValue: Value { get }
    func resetCache()
  }

  final class _CachedReference<Base: Reference>:
    Reference,
    @unchecked Sendable,
    _CachedReferenceProtocol
  {
    private let base: Base
    private let lock = NSRecursiveLock()
    private var _cachedValue: Base.Value

    var cachedValue: Base.Value {
      get { lock.withLock { _cachedValue } }
      set { lock.withLock { _cachedValue = newValue } }
    }

    init(base: Base) {
      self.base = base
      self._cachedValue = base.wrappedValue
    }

    var id: ObjectIdentifier {
      base.id
    }

    var loadError: (any Error)? {
      base.loadError
    }

    var wrappedValue: Base.Value {
      base.wrappedValue
    }

    func load() throws {
      try base.load()
    }

    func touch() {
      base.touch()
    }

    #if canImport(Combine)
      var publisher: any Publisher<Base.Value, Never> {
        base.publisher
      }
    #endif

    func resetCache() {
      cachedValue = wrappedValue
    }

    var description: String {
      base.description
    }
  }

  extension _CachedReference: MutableReference, Equatable where Base: MutableReference {
    var saveError: (any Error)? {
      base.saveError
    }

    var snapshot: Base.Value? {
      base.snapshot
    }

    func takeSnapshot(
      _ value: Base.Value,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      base.takeSnapshot(value, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    func withLock<R>(_ body: (inout Base.Value) throws -> R) rethrows -> R {
      try base.withLock { value in
        cachedValue = value
        return try body(&value)
      }
    }

    func save() throws {
      try base.save()
    }

    static func == (lhs: _CachedReference, rhs: _CachedReference) -> Bool {
      lhs.base == rhs.base
    }
  }
#endif
