import { t } from "../i18n";
import type { Toast } from "../hooks/useBreeClient";
import type { Id } from "bree/raw";

interface ToastsProps {
  toasts: Toast[];
  onDismiss(notification: Id): void;
}

export function Toasts({ toasts, onDismiss }: ToastsProps) {
  return (
    <div className="toast-stack" aria-live="polite">
      {toasts.map((toast) => (
        <article className={`toast ${toast.level}`} key={toast.notification}>
          <div><strong>{toast.title}</strong><p>{toast.body}</p></div>
          <button type="button" onClick={() => onDismiss(toast.notification)} aria-label={t("closeNotification")}>×</button>
        </article>
      ))}
    </div>
  );
}
