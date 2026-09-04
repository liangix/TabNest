import WebKit

/// Sends invalidations only, in an isolated world; native code still owns color sampling.
@MainActor
final class PageAppearanceObserver: NSObject, WKScriptMessageHandler {
    static let handlerName = "tabNestPageAppearance"
    static let fallbackInterval: TimeInterval = 3
    static let throttleMilliseconds = 80
    var onChange: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        onChange?()
    }

    static let installScript = """
    (() => {
      if (window.__tabNestPageAppearance) return;
      let active = false, timer = null, lastSent = -Infinity;
      const media = matchMedia('(prefers-color-scheme: dark)');
      function schedule() {
        if (!active || timer !== null) return;
        // Leading update is immediate; bursts coalesce with a trailing update.
        timer = setTimeout(() => {
          timer = null;
          if (!active) return;
          lastSent = performance.now();
          window.webkit.messageHandlers.\(handlerName).postMessage(null);
        }, Math.max(0, \(throttleMilliseconds) - (performance.now() - lastSent)));
      }
      const mutations = new MutationObserver(schedule);
      const events = ['scroll', 'resize', 'pageshow', 'load', 'transitionend', 'animationend'];
      window.__tabNestPageAppearance = {
        get active() { return active; },
        setActive(value) {
          if (active === value) return;
          active = value;
          if (active) {
            lastSent = -Infinity;
            for (const name of events) window.addEventListener(name, schedule, {capture: true, passive: true});
            media.addEventListener('change', schedule);
            mutations.observe(document, {
              subtree: true, childList: true, characterData: true, attributes: true,
              attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode',
                'data-color-scheme', 'color-scheme', 'media', 'href', 'disabled']
            });
            schedule();
          } else {
            for (const name of events) window.removeEventListener(name, schedule, true);
            media.removeEventListener('change', schedule);
            mutations.disconnect();
            if (timer !== null) clearTimeout(timer);
            timer = null;
          }
        }
      };
    })();
    """
}
