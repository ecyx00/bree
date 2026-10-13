import type { DiffResponse } from "./diff/generated/protocol";

export {};

declare global {
  /// Opaque sanitizer policy built by `Resources/markdown-viewer/markdown-sanitizer.js`.
  type BreeMarkdownSanitizerProfile = { readonly __breeMarkdownSanitizerProfile?: never };

  type BreeMarkdownSanitizerURLContext = {
    namespace: string;
    tag: string;
    name: string;
    value: string;
  };

  var BreeMarkdownSanitizer: {
    markdownProfile(options?: {
      removeElements?: string[];
      extraAttributes?: Record<string, string[]>;
      url?: (context: BreeMarkdownSanitizerURLContext) => string | null;
      element?: (source: Element, clean: Element) => boolean;
    }): BreeMarkdownSanitizerProfile;
    diagramProfile(): BreeMarkdownSanitizerProfile;
    sanitizeToFragment(
      html: string,
      options: { document: Document; profile: BreeMarkdownSanitizerProfile },
    ): DocumentFragment;
    serializeFragment(fragment: DocumentFragment, targetDocument: Document): string;
    sanitizeCSS(text: string): string | null;
  };

  var BreeViewerNavigation: {
    install(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
      shortcuts: Record<string, unknown>;
    }): () => void;
    installManualInputReset(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
    }): () => void;
    performAction(action: string, scroller: HTMLElement): boolean;
    resetSmoothTarget(scroller: HTMLElement): void;
  };

  interface Window {
    __breePerformDiffViewerNavigationAction?: (action: string) => boolean;
    __breeDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    webkit?: {
      messageHandlers?: {
        breeDiff?: {
          postMessage(message: unknown): Promise<DiffResponse>;
        };
      };
    };
  }
}
