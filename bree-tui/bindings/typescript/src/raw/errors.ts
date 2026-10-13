import type { BreeCommand } from "./generated/commands.js";
import type { BreeAuthority } from "./generated/metadata.js";

export class BreeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}

export class BreeCommandError extends BreeError {
  readonly commandId: unknown;
  readonly response: unknown;

  constructor(message: string, commandId?: unknown, response?: unknown) {
    super(message);
    this.commandId = commandId;
    this.response = response;
  }
}

export class BreeConnectionError extends BreeError {}
/** The server rejected the WebSocket credential before routing requests. */
export class BreeAuthenticationRejectedError extends BreeConnectionError {}
export class BreeProtocolError extends BreeError {}
export class BreeTimeoutError extends BreeError {}
export class BreeAbortError extends BreeError {}

/** A command was blocked locally because its authority was not enabled. */
export class BreeAuthorityError extends BreeError {
  readonly command: BreeCommand;
  readonly requiredAuthority: BreeAuthority;
  readonly grantedAuthorities: readonly BreeAuthority[];

  constructor(
    command: BreeCommand,
    requiredAuthority: BreeAuthority,
    grantedAuthorities: readonly BreeAuthority[],
  ) {
    super(`${command} requires ${requiredAuthority} authority`);
    this.command = command;
    this.requiredAuthority = requiredAuthority;
    this.grantedAuthorities = Object.freeze([...grantedAuthorities]);
  }
}
