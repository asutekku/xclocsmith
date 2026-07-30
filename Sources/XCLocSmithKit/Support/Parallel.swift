import Foundation

/// Maps over independent per-file work across cores, in index order.
///
/// Every caller here is doing the same thing — read or analyze one Swift file,
/// which touches nothing outside itself — and the results are merged in the
/// original order, so a parallel run reports exactly what a serial one did.
func parallelMap<Element, Result>(
    _ elements: [Element],
    _ transform: (Element) -> Result
) -> [Result] {
    guard elements.count > 1 else { return elements.map(transform) }
    var results = [Result?](repeating: nil, count: elements.count)
    results.withUnsafeMutableBufferPointer { buffer in
        let slots = buffer
        DispatchQueue.concurrentPerform(iterations: elements.count) { index in
            slots[index] = transform(elements[index])
        }
    }
    return results.map { $0! }
}
