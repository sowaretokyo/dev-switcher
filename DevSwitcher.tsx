/**
 * Dev Switcher — メインウィンドウ
 *
 * HTMLモック (dev-switcher.html) と同じクラス名を使っているので、
 * あちらの <style> の「macOS MOCK」以降をそのまま dev-switcher.css として流用できます。
 *
 * 設計上の不変条件（ここを崩すと安全性が壊れます）:
 *   1. sheet.kind !== "none" のとき <Sheet> がサイドバーの上に被さり、イベントを遮る。
 *      disabled 属性ではなくモーダルで遮る。スタイルの都合で無効化が外れる事故を構造で防ぐ。
 *   2. サイドバーは選択しか発火しない。切替・起動・停止は明示的なボタンだけ。
 *   3. 起動フェーズに入った後は cancel を受け付けない（停止の取り消しは実装不能なため）。
 *   4. エラーシートには必ず <CurrentState /> を出す。両プロジェクトの現在地を必ず断言する。
 *
 * CSSのクラス名について:
 *   単語1つの修飾クラス（err / warn / wide / pop など）をコンテナ名と共有しないこと。
 *   `.ll.err` が `.err`（シート）にマッチして padding が漏れる、という事故が実際に起きました。
 *   修飾クラスは lvl-err のように必ず名前空間を付けます。
 */

import { useCallback, useMemo, useState } from "react";

/* ============================================================
   Domain — 形態に依存しない部分
   ============================================================ */

/** "excluded" = 今回の起動対象から外されている。停止中とは別物で、警告を出さない。 */
export type ServiceState = "excluded" | "stopped" | "starting" | "running" | "failed";

export interface PortSpec {
  /** "API" / "DB" / "Studio" など。単一ポートのサービスでは省略可 */
  label?: string;
  port: number;
  /** ブラウザで開けるなら URL。「開く▾」メニューに載る */
  openUrl?: string;
}

export interface Service {
  id: string;
  name: string;
  /** 1つとは限らない。Supabase は API/DB/Studio/Inbucket/Analytics で5〜7個。ports[0] が代表。 */
  ports: PortSpec[];
  command: string;
  /** 既定で起動対象にするか */
  enabledByDefault: boolean;
  /** 起動に失敗したときプロジェクト全体を失敗にするか */
  failurePolicy: "block" | "continue";
}

export interface Project {
  id: string;
  name: string;
  /** サイドバーの識別用。角丸四角チップで描く（丸いドットには使わない） */
  initial: string;
  color: string;
  directory: string;
  /** 配列順が起動順。終了順は既定でこの逆。 */
  services: Service[];
  /** 逆順を上書きするときだけ。service id の配列。 */
  stopOrder?: string[];
  /** 今回の起動で対象にするサービス。未設定なら enabledByDefault に従う。設定なので永続化してよい。 */
  enabledNow?: Record<string, boolean>;
  lastUsedLabel: string;
}

/** プロセスの状態。モーダルUIとは独立。 */
export type Phase =
  | { kind: "idle" }
  | { kind: "starting"; projectId: string }
  /** listen は始まったがヘルスチェックが通らないままタイムアウトした（決定 d） */
  | { kind: "stalled"; projectId: string; serviceId: string; elapsedSec: number }
  | { kind: "running"; projectId: string; startedAt: number }
  | { kind: "stopping"; projectId: string };

/** モーダルUI。出ている間はサイドバーに手が届かない。 */
export type Sheet =
  | { kind: "none" }
  | { kind: "switching"; fromId: string; toId: string; step: SwitchStep }
  | { kind: "failed"; error: SwitchError }
  | { kind: "adopt"; found: FoundProcess[]; guessedProjectId: string | null }
  | { kind: "wizard"; step: number };

/** 切替の進行位置。gate が停止フェーズと起動フェーズの境目。 */
export type SwitchStep =
  | { at: "stopping"; index: number }
  | { at: "gate"; release: GateCheck; acquire: GateCheck }
  | { at: "starting"; index: number };

/**
 * ゲートは2つの独立した検証からなる（I-3）。
 * release: 停止元が実際に握っていたポートが解放されたか（ソース = 実測）
 * acquire: 今回起動するサービスのポートが空いているか（ソース = 設定値）
 * failurePolicy はここでは一切使わない。continue のサービスのポートも必ず検証する。
 */
export interface GateCheck {
  state: "pending" | "passed" | "blocked";
  done: number;
  total: number;
}

export type SwitchError =
  | {
      kind: "port-conflict";
      port: number;
      holder: PortHolder;
      currentState: CurrentStateFacts;
    }
  | {
      kind: "stop-timeout";
      survivors: Array<{ pid: number; name: string; port: number }>;
      currentState: CurrentStateFacts;
    }
  | {
      kind: "boot-crash";
      serviceId: string;
      serviceName: string;
      logTail: LogLine[];
      currentState: CurrentStateFacts;
    };

/** 決定 c: 誰が持っているかで扱いを変える。 */
export interface PortHolder {
  pid: number;
  command: string;
  cwd: string;
  /** Dev Switcher が起動したプロセスか */
  ownedByUs: boolean;
  /** Docker デーモン配下なら kill ではなく docker stop */
  managedByDocker: boolean;
  /** launchd 管理下 / 別オーナー。終了ボタンを出さない。 */
  systemOwned: boolean;
}

/** 失敗時に必ず埋める「いま何がどうなっているか」。省略可能にしない。 */
export interface CurrentStateFacts {
  headline: string;
  detail: string;
}

export interface FoundProcess {
  pid: number;
  port: number;
  command: string;
}

export interface LogLine {
  ts: string;
  level: "info" | "warn" | "error";
  text: string;
}

export type Selection =
  | { kind: "project"; projectId: string }
  | { kind: "service"; projectId: string; serviceId: string };

/** "excluded" は中空の丸で描く。色を持たない＝状態ではない。 */
export type StatusTone = "running" | "stopped" | "warn" | "fail" | "busy" | "excluded";

/* ============================================================
   Derivations
   ============================================================ */

/** 今回の起動対象か。enabledNow > enabledByDefault の順で解決する。 */
export function isEnabled(project: Project, service: Service): boolean {
  return project.enabledNow?.[service.id] ?? service.enabledByDefault;
}

export function enabledServices(project: Project): Service[] {
  return project.services.filter((s) => isEnabled(project, s));
}

/**
 * 一部停止の検出。
 * 決定 h: 対象外のサービスは含めない。意図的に外したものを警告に混ぜると嘘になる。
 */
export function isDegraded(project: Project, states: Record<string, ServiceState>): boolean {
  return enabledServices(project).some(
    (s) => s.failurePolicy === "continue" && states[s.id] !== "running",
  );
}

/** 終了順は起動順の逆。stopOrder があればそれを優先する。 */
export function stopOrder(project: Project): Service[] {
  if (!project.stopOrder) return [...project.services].reverse();
  const byId = new Map(project.services.map((s) => [s.id, s]));
  const ordered = project.stopOrder.map((id) => byId.get(id)).filter((s): s is Service => !!s);
  // stopOrder に載っていないサービスは末尾に回す
  const rest = project.services.filter((s) => !project.stopOrder!.includes(s.id));
  return [...ordered, ...rest];
}

/**
 * ゲート検証1（停止側）が待つポート。
 * ソースは設定値ではなく実測。引き継いだプロジェクトや設定変更後のプロセスでは
 * 設定値と実際に握っているポートが食い違うため（I-3 / I-8）。
 */
export function portsToRelease(observed: ObservedPorts): number[] {
  return Object.values(observed).flat();
}

/** ゲート検証2（起動側）が空きを要求するポート。こちらは設定値。 */
export function portsToAcquire(project: Project): number[] {
  return enabledServices(project).flatMap((s) => s.ports.map((p) => p.port));
}

/** 起動時に観測した listen ポート。service id -> ports。 */
export type ObservedPorts = Record<string, number[]>;

/** 「開く▾」メニューの中身。openUrl を持つポートだけが載る。 */
export function openableTargets(project: Project): Array<{ label: string; url: string }> {
  return enabledServices(project).flatMap((s) =>
    s.ports
      .filter((p) => !!p.openUrl)
      .map((p) => ({ label: p.label ? `${s.name} · ${p.label}` : s.name, url: p.openUrl! })),
  );
}

function toneOf(state: ServiceState): StatusTone {
  switch (state) {
    case "running":
      return "running";
    case "starting":
      return "busy";
    case "failed":
      return "fail";
    case "excluded":
      return "excluded";
    default:
      return "stopped";
  }
}

function isExpoService(name: string): boolean {
  return /expo|native/i.test(name);
}

/* ============================================================
   Primitives
   ============================================================ */

export function ProjectChip({ project, small }: { project: Project; small?: boolean }) {
  return (
    <span className={small ? "pchip sm" : "pchip"} style={{ background: project.color }}>
      {project.initial}
    </span>
  );
}

export function StatusDot({ tone }: { tone: StatusTone }) {
  return <span className={`dot ${tone}`} />;
}

/* ============================================================
   Toolbar
   ============================================================ */

export function Toolbar({
  project,
  statusLabel,
  tone,
  busy,
  onOpenBrowser,
  onOpenEditor,
  onStop,
}: {
  project: Project | null;
  statusLabel: string;
  tone: StatusTone;
  busy: boolean;
  onOpenBrowser: () => void;
  onOpenEditor: () => void;
  onStop: () => void;
}) {
  return (
    <div className="tbar">
      <span className="tl">
        <i />
        <i />
        <i />
      </span>
      {project ? (
        <span className="tb-proj">
          <ProjectChip project={project} />
          <span className="tb-name">{project.name}</span>
          <span className="tb-state">
            {statusLabel}
            <StatusDot tone={tone} />
          </span>
        </span>
      ) : (
        <span className="tb-proj">
          <span className="tb-state">起動中のプロジェクトはありません</span>
        </span>
      )}
      <span className="spacer" />
      <button className="btn split" disabled={!project || busy} onClick={onOpenBrowser}>
        <ExternalIcon />
        開く
        <span className="div" />
        <span className="car">
          <ChevronDownIcon />
        </span>
      </button>
      <button className="btn" disabled={!project || busy} onClick={onOpenEditor}>
        <CodeIcon />
        Cursor
      </button>
      <button className="btn danger" disabled={!project} onClick={onStop}>
        <StopIcon />
        {busy ? "中止" : "停止"}
      </button>
    </div>
  );
}

/* ============================================================
   Sidebar — 選択しか発火しない（不変条件 2）
   ============================================================ */

export interface SidebarProps {
  projects: Project[];
  activeId: string | null;
  selection: Selection;
  serviceStates: Record<string, ServiceState>;
  unreadErrors: Record<string, number>;
  expanded: Record<string, boolean>;
  /** false = 起動順, true = 終了順 */
  reverseOrder: boolean;
  onSelect: (selection: Selection) => void;
  onToggleExpand: (projectId: string) => void;
  onToggleOrder: () => void;
  onAddProject: () => void;
  onOpenSettings: () => void;
}

export function Sidebar(props: SidebarProps) {
  const { projects, activeId } = props;
  const active = activeId ? projects.find((p) => p.id === activeId) ?? null : null;
  const others = projects.filter((p) => p.id !== activeId);

  return (
    <div className="side">
      <div className="side-scroll">
        <div className="side-sec">稼働中</div>
        {active ? (
          <ProjectRow project={active} isActive {...props} />
        ) : (
          <div className="srow" style={{ color: "var(--m-text-3)" }}>
            <span className="nm">なし</span>
          </div>
        )}

        <div className="side-sec">プロジェクト</div>
        {others.map((p) => (
          <ProjectRow key={p.id} project={p} isActive={false} {...props} />
        ))}
      </div>
      <div className="side-foot">
        <button className="fbtn" onClick={props.onAddProject}>
          <PlusIcon />
          プロジェクトを追加…
        </button>
        <span className="spacer" />
        <button className="fbtn" aria-label="設定" onClick={props.onOpenSettings}>
          <GearIcon />
        </button>
      </div>
    </div>
  );
}

function ProjectRow({
  project,
  isActive,
  ...props
}: SidebarProps & { project: Project; isActive: boolean }) {
  const { selection, expanded, serviceStates } = props;
  const selected = selection.kind === "project" && selection.projectId === project.id;
  const open = !!expanded[project.id];
  const tone: StatusTone = isActive
    ? isDegraded(project, serviceStates)
      ? "warn"
      : "running"
    : "stopped";

  return (
    <>
      <div
        className={open ? "srow open" : "srow"}
        role="option"
        tabIndex={0}
        aria-selected={selected}
        onClick={() => props.onSelect({ kind: "project", projectId: project.id })}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            props.onSelect({ kind: "project", projectId: project.id });
          }
        }}
      >
        <span
          className="tri"
          onClick={(e) => {
            e.stopPropagation();
            props.onToggleExpand(project.id);
          }}
        >
          <TriangleIcon />
        </span>
        <ProjectChip project={project} small />
        <span className="nm">{project.name}</span>
        {isActive ? <StatusDot tone={tone} /> : <span className="tw">{project.lastUsedLabel}</span>}
      </div>

      {open && <ServiceRows project={project} isActive={isActive} {...props} />}
    </>
  );
}

export function ServiceRows({
  project,
  isActive,
  ...props
}: SidebarProps & { project: Project; isActive: boolean }) {
  const { selection, serviceStates, unreadErrors, reverseOrder } = props;
  const list = reverseOrder ? stopOrder(project) : project.services;

  return (
    <>
      {/* 順序は並び順で伝える。ラベルをクリックすると終了順（逆順）に切り替わる。 */}
      <div className="side-cap" role="button" tabIndex={0} onClick={props.onToggleOrder}>
        <UpDownIcon />
        {reverseOrder ? "終了順" : "起動順"}
      </div>
      {list.map((s) => {
        const selected =
          selection.kind === "service" &&
          selection.projectId === project.id &&
          selection.serviceId === s.id;
        const enabled = isEnabled(project, s);
        const state: ServiceState = !enabled
          ? "excluded"
          : isActive
            ? serviceStates[s.id] ?? "stopped"
            : "stopped";
        const errors = unreadErrors[s.id] ?? 0;
        return (
          <div
            key={s.id}
            className="srow svc"
            role="option"
            tabIndex={0}
            aria-selected={selected}
            onClick={() =>
              props.onSelect({ kind: "service", projectId: project.id, serviceId: s.id })
            }
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                props.onSelect({ kind: "service", projectId: project.id, serviceId: s.id });
              }
            }}
          >
            <StatusDot tone={toneOf(state)} />
            <span className="nm">{s.name}</span>
            {/* ログのエラーは状態に昇格させない。ドットは緑のまま、バッジだけ出す。 */}
            {errors > 0 && (
              <span className="errb" title="未読のエラー行">
                {errors}
              </span>
            )}
            {/* 代表ポート + 残数。全部出すと 214pt の行が破綻する（決定 g） */}
            <span className="pt">
              {enabled ? (
                <>
                  :{s.ports[0]?.port}
                  {s.ports.length > 1 && <span className="more"> +{s.ports.length - 1}</span>}
                </>
              ) : (
                "対象外"
              )}
            </span>
          </div>
        );
      })}
    </>
  );
}

/* ============================================================
   Detail pane
   ============================================================ */

export function ProjectDetail({
  project,
  activeProject,
  serviceStates,
  onSwitch,
  onToggleEnabled,
  onOpenMenu,
}: {
  project: Project;
  activeProject: Project | null;
  serviceStates: Record<string, ServiceState>;
  onSwitch: () => void;
  /** 今回の起動対象を切り替える。enabledNow に永続化される（決定 h） */
  onToggleEnabled: (serviceId: string) => void;
  onOpenMenu: () => void;
}) {
  const isActive = activeProject?.id === project.id;
  const enabledCount = enabledServices(project).length;

  return (
    <div className="detail">
      <div className="dhead">
        <span className="nm">{project.name}</span>
        <span className="spacer" />
        <button className="sbtn" aria-label="このプロジェクトの操作" onClick={onOpenMenu}>
          <EllipsisIcon />
        </button>
      </div>
      <div className="dempty">
        <ProjectChip project={project} />
        <div>
          <div className="big">
            {isActive ? project.name : `${project.name} は停止しています`}
          </div>
          <div className="sm">
            {isActive ? "サービスを選ぶとログが表示されます" : `最終起動 ${project.lastUsedLabel}`}
          </div>
        </div>

        {/* 停止中は「何を起動するか」を選べる。稼働中は結果の表示だけ。 */}
        <div className="svclist">
          {project.services.map((s) => {
            const enabled = isEnabled(project, s);
            const state: ServiceState = !enabled
              ? "excluded"
              : isActive
                ? serviceStates[s.id] ?? "stopped"
                : "stopped";
            const content = (
              <>
                <StatusDot tone={toneOf(state)} />
                {s.name}
                <span className="p">
                  :{s.ports[0]?.port}
                  {s.ports.length > 1 && ` +${s.ports.length - 1}`}
                </span>
              </>
            );
            return isActive ? (
              <span className="sv" key={s.id}>
                {content}
              </span>
            ) : (
              <button
                className={enabled ? "sv" : "sv off"}
                key={s.id}
                aria-pressed={enabled}
                onClick={() => onToggleEnabled(s.id)}
              >
                {content}
              </button>
            );
          })}
        </div>

        {!isActive && (
          <>
            <button className="btn prim lg" disabled={enabledCount === 0} onClick={onSwitch}>
              <SwapIcon />
              {activeProject
                ? `${activeProject.name} を停止して ${project.name} を起動`
                : `${project.name} を起動`}
            </button>
            <div className="sm" style={{ maxWidth: 300 }}>
              {enabledCount === 0
                ? "起動するサービスがありません。上から選んでください。"
                : "選択しただけでは何も起こりません。実行はこのボタンだけです。"}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export function ServiceDetail({
  service,
  state,
  isActive,
  lines,
  follow,
  inspectorOpen,
  banner,
  onToggleInspector,
  onToggleFollow,
  onClear,
}: {
  service: Service;
  state: ServiceState;
  isActive: boolean;
  lines: LogLine[];
  follow: boolean;
  inspectorOpen: boolean;
  banner: React.ReactNode;
  onToggleInspector: () => void;
  onToggleFollow: () => void;
  onClear: () => void;
}) {
  const tone = toneOf(state);
  const stateLabel =
    state === "excluded"
      ? "対象外"
      : !isActive || state === "stopped"
        ? "停止中"
        : state === "starting"
          ? "応答待ち"
          : state === "failed"
            ? "失敗"
            : "稼働中";

  let prevTs = "";

  return (
    <div className="detail">
      <div className="dhead">
        <span className="nm">{service.name}</span>
        {/* サイドバーは代表ポート + N、ここで全部出す（決定 g） */}
        <span className="dm">
          {service.ports
            .map((p) => (p.label ? `${p.label} :${p.port}` : `:${p.port}`))
            .join(" · ")}
        </span>
        {/* failurePolicy はサイドバーに出さず、ここにだけ出す */}
        <span className="rq">{service.failurePolicy === "block" ? "必須" : "任意"}</span>
        <span className="spacer" />
        {isExpoService(service.name) && (
          <button className="sbtn" aria-pressed={inspectorOpen} onClick={onToggleInspector}>
            <QRIcon />
            QR
          </button>
        )}
        <span className="st">
          {stateLabel}
          <StatusDot tone={tone} />
        </span>
      </div>

      {banner}

      <div className="logbar">
        <span className="lsearch">
          <SearchIcon />
          絞り込み
        </span>
        <button className="btn tiny" aria-pressed={follow} onClick={onToggleFollow}>
          追従
        </button>
        <button className="btn tiny" aria-label="消去" onClick={onClear}>
          <TrashIcon />
        </button>
      </div>

      <div className="logout">
        {lines.map((l, i) => {
          const cont = l.ts === prevTs;
          prevTs = l.ts;
          /* 修飾クラスは必ず名前空間付き。`err` 単体はシートのコンテナ名と衝突する。 */
          const cls = [
            "ll",
            l.level === "warn" ? "lvl-warn" : l.level === "error" ? "lvl-err" : "",
            cont ? "cont" : "",
          ]
            .filter(Boolean)
            .join(" ");
          return (
            <div className={cls} key={i}>
              <span className="ts">{l.ts}</span>
              <span className="tx">{l.text}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** ヘルスチェックがタイムアウトしたときの帯。黙って待ち続けない（決定 d）。 */
export function StallBanner({
  elapsedSec,
  port,
  onKeepWaiting,
  onAbort,
}: {
  elapsedSec: number;
  port: number;
  onKeepWaiting: () => void;
  onAbort: () => void;
}) {
  return (
    <div className="banner">
      <StatusDot tone="busy" />
      <span className="tx">
        <b>{elapsedSec} 秒応答していません。</b>
        ポート {port} は開いていますが、ヘルスチェックがまだ通りません。
      </span>
      <button className="btn tiny" onClick={onKeepWaiting}>
        待ち続ける
      </button>
      <button className="btn tiny danger" onClick={onAbort}>
        起動を中止
      </button>
    </div>
  );
}

/** 任意サービスが落ちたときの帯。エラーシートは出さないが、黙って隠さない。 */
export function DegradedBanner({ onRestart }: { onRestart: () => void }) {
  return (
    <div className="banner" style={{ background: "rgba(255,159,10,.12)" }}>
      <StatusDot tone="warn" />
      <span className="tx">
        <b>停止しています。</b>任意サービスのため、プロジェクトは稼働中のままです。
      </span>
      <button className="btn tiny" onClick={onRestart}>
        再起動
      </button>
    </div>
  );
}

/* ============================================================
   Expo inspector — ポップオーバーと違い、他を触っても閉じない
   ============================================================ */

export type ExpoMode = "lan" | "tunnel" | "localhost";

export function ExpoInspector({
  url,
  qr,
  mode,
  reachability,
  onModeChange,
  onCopyUrl,
  onOpenIOS,
  onOpenAndroid,
  onClose,
}: {
  /** Expo の実出力から取得した URL。取れなければ null（推測で埋めない）。 */
  url: string | null;
  /** QR の SVG マークアップ。url から毎回生成し、キャッシュしない。 */
  qr: string | null;
  mode: ExpoMode;
  /** 実機から届かない可能性がある場合の理由。無ければ null。 */
  reachability: { reason: string; hint: string } | null;
  onModeChange: (mode: ExpoMode) => void;
  onCopyUrl: () => void;
  onOpenIOS: () => void;
  onOpenAndroid: () => void;
  onClose: () => void;
}) {
  return (
    <div className="insp">
      <div className="insp-h">
        Expo
        <span className="spacer" />
        <button className="sbtn" aria-label="閉じる" onClick={onClose}>
          ✕
        </button>
      </div>
      <div className="insp-b">
        {/* QR は白地固定。ダークモードでも反転させない（読み取り精度のため）。 */}
        {qr && url ? (
          <div className="qrcard" dangerouslySetInnerHTML={{ __html: qr }} />
        ) : (
          <div className="qrcard" style={{ minHeight: 148, color: "#666", fontSize: 12 }}>
            接続先を取得できません
          </div>
        )}

        <div className="urlrow">
          <span className="u">{url ?? "—"}</span>
          <button className="sbtn" aria-label="URLをコピー" disabled={!url} onClick={onCopyUrl}>
            <CopyIcon />
          </button>
        </div>

        <div className="insp-line">
          <span className="lb">接続</span>
          <span className="seg">
            {(
              [
                ["lan", "LAN"],
                ["tunnel", "トンネル"],
                ["localhost", "ローカル"],
              ] as Array<[ExpoMode, string]>
            ).map(([key, label]) => (
              <span key={key} aria-pressed={mode === key} onClick={() => onModeChange(key)}>
                {label}
              </span>
            ))}
          </span>
        </div>

        <div className="insp-acts">
          <button className="btn" onClick={onOpenIOS}>
            iOS
          </button>
          <button className="btn" onClick={onOpenAndroid}>
            Android
          </button>
        </div>
      </div>

      {reachability && (
        <div className="insp-warn">
          <span className="ic">
            <WarnIcon />
          </span>
          <span className="tx">
            {reachability.reason}
            <br />
            <em>{reachability.hint}</em>
          </span>
        </div>
      )}
    </div>
  );
}

/* ============================================================
   Sheets — 出ている間はサイドバーに手が届かない（不変条件 1）
   ============================================================ */

export function TransitionSheet({
  from,
  to,
  step,
  observed,
  onCancel,
  onInspectBlocker,
}: {
  from: Project;
  to: Project;
  step: SwitchStep;
  /** 停止元が実際に握っていたポート。ゲート検証1のソース（I-3） */
  observed: ObservedPorts;
  onCancel: () => void;
  onInspectBlocker: () => void;
}) {
  /** 停止するのは「実際に起動していたもの」＝観測済みのサービスだけ */
  const stopSeq = stopOrder(from).filter((s) => (observed[s.id] ?? []).length > 0);
  /** 起動するのは今回の対象サービスだけ */
  const startSeq = enabledServices(to);
  const blocked =
    step.at === "gate" && (step.release.state === "blocked" || step.acquire.state === "blocked");
  const inStartPhase = step.at === "starting";
  /** 起動が始まったら中止は受け付けない（停止の取り消しは実装不能） */
  const canCancel = step.at === "stopping";

  return (
    <div className="tr">
      <div className="tr-head">
        <ProjectChip project={from} small />
        <span className="nm">{from.name}</span>
        <span className="ar">→</span>
        <ProjectChip project={to} small />
        <span className="nm">{to.name}</span>
      </div>
      <div className="tr-sub">{blocked ? "切り替えを中断しました" : "切り替えています…"}</div>

      <div className="tr-phase">終了順　{from.name}</div>
      {stopSeq.map((s, i) => {
        const state =
          step.at !== "stopping" ? "done" : i < step.index ? "done" : i === step.index ? "now" : "wait";
        return <StepRow key={s.id} name={s.name} state={state} doneLabel="停止" nowLabel="停止中…" />;
      })}

      <GateRow
        step={step}
        from={from}
        to={to}
        releaseTotal={portsToRelease(observed).length}
        acquireTotal={portsToAcquire(to).length}
      />

      <div className="tr-phase">起動順　{to.name}</div>
      {startSeq.map((s, i) => {
        const state = !inStartPhase
          ? "wait"
          : i < step.index
            ? "done"
            : i === step.index
              ? "now"
              : "wait";
        return <StepRow key={s.id} name={s.name} state={state} doneLabel="稼働" nowLabel="起動中…" />;
      })}

      <div className="tr-foot">
        {blocked ? (
          <>
            <button className="btn prim" onClick={onInspectBlocker}>
              占有プロセスを見る
            </button>
            <span className="hint">
              {to.name} は起動していません。
              <br />
              {from.name} は完全に停止しました。
            </span>
          </>
        ) : (
          <>
            <button className="btn" disabled={!canCancel} onClick={onCancel}>
              切替を中止
            </button>
            <span className="hint">
              {canCancel ? (
                <>
                  {from.name} の停止は最後まで実行し、
                  <br />
                  {to.name} は起動しません。
                </>
              ) : (
                <>
                  起動が始まったため中止できません。
                  <br />
                  停止するには起動完了を待ってください。
                </>
              )}
            </span>
          </>
        )}
      </div>
    </div>
  );
}

function StepRow({
  name,
  state,
  doneLabel,
  nowLabel,
}: {
  name: string;
  state: "done" | "now" | "wait";
  doneLabel: string;
  nowLabel: string;
}) {
  return (
    <div className={`tr-step ${state}`}>
      <span className="ic">
        {state === "done" ? <CheckIcon /> : state === "now" ? <span className="spin" /> : <CircleIcon />}
      </span>
      <span className="nm">{name}</span>
      <span className="st">{state === "done" ? doneLabel : state === "now" ? nowLabel : ""}</span>
    </div>
  );
}

/**
 * ゲート。ここが通らない限り起動フェーズには進まない。
 *
 * I-3: 2つの独立した検証からなる。failurePolicy は一切見ない。
 *   1. 停止元が実際に握っていた全ポートが解放されたか（実測）
 *   2. 今回起動する全サービスのポートが空いているか（設定値）
 * 1 を先に検証する。2 の競合は 1 の残存が原因であることが多く、原因に近いエラーが出る。
 */
export function GateRow({
  step,
  from,
  to,
  releaseTotal,
  acquireTotal,
}: {
  step: SwitchStep;
  from: Project;
  to: Project;
  releaseTotal: number;
  acquireTotal: number;
}) {
  const release: GateCheck =
    step.at === "gate"
      ? step.release
      : step.at === "starting"
        ? { state: "passed", done: releaseTotal, total: releaseTotal }
        : { state: "pending", done: 0, total: releaseTotal };
  const acquire: GateCheck =
    step.at === "gate"
      ? step.acquire
      : step.at === "starting"
        ? { state: "passed", done: acquireTotal, total: acquireTotal }
        : { state: "pending", done: 0, total: acquireTotal };

  const blocked = release.state === "blocked" || acquire.state === "blocked";
  const cls = blocked ? "gate blocked" : release.state === "passed" && acquire.state === "passed" ? "gate armed" : "gate";

  return (
    <div className={cls}>
      <GateLine label={`${from.name} のポートが解放された`} check={release} />
      <GateLine label={`${to.name} のポートを確認`} check={acquire} />
    </div>
  );
}

function GateLine({ label, check }: { label: string; check: GateCheck }) {
  const color =
    check.state === "blocked"
      ? "var(--m-red)"
      : check.state === "passed"
        ? "var(--m-accent)"
        : "var(--m-text-3)";
  return (
    <div className="gate-line">
      <span className="ic" style={{ color }}>
        {check.state === "passed" ? <CheckIcon /> : check.state === "blocked" ? <LockIcon /> : <span className="spin" />}
      </span>
      <span className="gt">{label}</span>
      <span className="gs" style={check.state === "blocked" ? { color: "var(--m-red)" } : undefined}>
        {check.done} / {check.total}
      </span>
    </div>
  );
}

export function ErrorSheet({
  error,
  onClose,
  onRetry,
  onKillHolder,
  onCopyPid,
  onForceStop,
  onOpenServiceLog,
}: {
  error: SwitchError;
  onClose: () => void;
  onRetry: () => void;
  onKillHolder: () => void;
  onCopyPid: (pid: number) => void;
  onForceStop: () => void;
  /** シートを閉じて、落ちたサービスを選択した状態にする */
  onOpenServiceLog: (serviceId: string) => void;
}) {
  return (
    <div className="err">
      {error.kind === "port-conflict" && (
        <>
          <ErrHead
            title="起動できませんでした"
            body={`必須サービスのポート ${error.port} が別のプロセスに使われています。`}
          />
          <div className="err-block">
            <div className="err-block-t">占有しているプロセス</div>
            <div className="err-row">
              <span className="p1">:{error.port}</span>
              <span className="p2">
                {error.holder.command} · PID {error.holder.pid}
              </span>
            </div>
            <div className="err-row">
              <span className="p1" style={{ visibility: "hidden" }}>
                :{error.port}
              </span>
              <span className="p2">{error.holder.cwd}</span>
            </div>
          </div>
          <div className="err-acts">
            <HolderAction
              holder={error.holder}
              onKill={onKillHolder}
              onCopyPid={() => onCopyPid(error.holder.pid)}
            />
            <span className="spacer" />
            <button className="btn prim" onClick={onClose}>
              閉じる
            </button>
          </div>
        </>
      )}

      {error.kind === "stop-timeout" && (
        <>
          <ErrHead title="完全に停止できませんでした" body="一部のプロセスが時間内に終了しませんでした。" />
          <div className="err-block">
            <div className="err-block-t">残っているプロセス</div>
            {error.survivors.map((s) => (
              <div className="err-row" key={s.pid}>
                <span className="p1">:{s.port}</span>
                <span className="p2">
                  {s.name} · PID {s.pid}
                </span>
              </div>
            ))}
          </div>
          <div className="err-acts">
            {/* 既定は安全側。破壊的な選択肢は塗らない・⏎を当てない。 */}
            <button className="btn prim" onClick={onClose}>
              切替を中止
            </button>
            <button className="btn danger" onClick={onForceStop}>
              強制終了して続行
            </button>
          </div>
        </>
      )}

      {error.kind === "boot-crash" && (
        <>
          <ErrHead
            title={`${error.serviceName} が起動直後に終了しました`}
            body="必須サービスのため、残りのサービスは起動していません。"
          />
          {/* stderr だけに絞ると「直前に何をしていたか」が消えるので時系列のまま出す */}
          <div className="log">
            {error.logTail.map((l, i) => (
              <div key={i} className={l.level === "error" ? "e" : undefined}>
                {l.text}
              </div>
            ))}
          </div>
          <div className="err-acts">
            <button className="btn prim" onClick={() => onOpenServiceLog(error.serviceId)}>
              <DocIcon />
              ログを開く
            </button>
            <button className="btn" onClick={onRetry}>
              再試行
            </button>
            <span className="spacer" />
            <button className="btn" onClick={onClose}>
              閉じる
            </button>
          </div>
        </>
      )}

      <CurrentState facts={error.currentState} />
    </div>
  );
}

/** 決定 c: 誰が持っているかで出せる操作が変わる。 */
function HolderAction({
  holder,
  onKill,
  onCopyPid,
}: {
  holder: PortHolder;
  onKill: () => void;
  onCopyPid: () => void;
}) {
  if (holder.systemOwned) {
    // launchd 管理下 / 別オーナー。殺すと他の作業まで壊れるので終了ボタンを出さない。
    return (
      <button className="btn" onClick={onCopyPid}>
        PID をコピー
      </button>
    );
  }
  return (
    <button className="btn" onClick={onKill}>
      {holder.managedByDocker ? "コンテナを停止して再試行" : "このプロセスを終了して再試行"}
    </button>
  );
}

function ErrHead({ title, body }: { title: string; body: string }) {
  return (
    <div className="err-top">
      <span className="ic">
        <WarnIcon />
      </span>
      <div>
        <div className="err-h">{title}</div>
        <div className="err-p">{body}</div>
      </div>
    </div>
  );
}

/** 失敗シートの必須要素。中途半端な状態を黙って放置しないための行。 */
function CurrentState({ facts }: { facts: CurrentStateFacts }) {
  return (
    <div className="truth">
      <span className="lb">現在</span>
      <span className="tx">
        {facts.headline}
        <br />
        <em>{facts.detail}</em>
      </span>
    </div>
  );
}

/**
 * 起動時に検出した既存プロセスの引き継ぎ（決定 e）。
 * 状態はディスクに保存せず、毎回実プロセスから再構築する。
 */
export function AdoptSheet({
  found,
  projectName,
  onAdopt,
  onStopAll,
  onIgnore,
}: {
  found: FoundProcess[];
  projectName: string | null;
  onAdopt: () => void;
  onStopAll: () => void;
  onIgnore: () => void;
}) {
  return (
    <div className="err">
      <div className="err-top">
        <span className="ic" style={{ color: "var(--m-accent)" }}>
          <RestoreIcon />
        </span>
        <div>
          <div className="err-h">起動中のプロセスが見つかりました</div>
          <div className="err-p">
            前回 Dev Switcher を終了したときの {projectName ?? "プロジェクト"} がまだ動いています。
          </div>
        </div>
      </div>
      <div className="err-block">
        <div className="err-block-t">検出したプロセス</div>
        {found.map((f) => (
          <div className="err-row" key={f.pid}>
            <span className="p1">:{f.port}</span>
            <span className="p2">
              {f.command} · PID {f.pid}
            </span>
          </div>
        ))}
      </div>
      <div className="err-acts">
        <button className="btn prim" disabled={!projectName} onClick={onAdopt}>
          {projectName ? `${projectName} として引き継ぐ` : "引き継げません"}
        </button>
        <button className="btn" onClick={onStopAll}>
          すべて停止
        </button>
        <span className="spacer" />
        <button className="btn" onClick={onIgnore}>
          無視
        </button>
      </div>
      <CurrentState
        facts={{
          headline: "Dev Switcher はまだ何も管理していません。",
          detail: "「無視」を選んでもポートは埋まったままです。次の切替はゲートで止まります。",
        }}
      />
    </div>
  );
}

/* ============================================================
   MainWindow
   ============================================================ */

export interface MainWindowProps {
  projects: Project[];
  phase: Phase;
  sheet: Sheet;
  selection: Selection;
  serviceStates: Record<string, ServiceState>;
  /** 起動時に観測した listen ポート。ゲート検証1のソース（I-3 / I-8） */
  observed: ObservedPorts;
  unreadErrors: Record<string, number>;
  logs: Record<string, LogLine[]>;
  expanded: Record<string, boolean>;
  reverseOrder: boolean;
  follow: boolean;
  inspectorOpen: boolean;
  elapsedLabel: string;
  expo: {
    url: string | null;
    qr: string | null;
    mode: ExpoMode;
    reachability: { reason: string; hint: string } | null;
  };
  onSelect: (selection: Selection) => void;
  onToggleExpand: (projectId: string) => void;
  onToggleOrder: () => void;
  onToggleFollow: () => void;
  onToggleInspector: () => void;
  onClearLog: () => void;
  onAddProject: () => void;
  onOpenSettings: () => void;
  onOpenBrowser: () => void;
  onOpenEditor: () => void;
  onStop: () => void;
  onSwitchTo: (projectId: string) => void;
  /** 今回の起動対象を切り替える（決定 h） */
  onToggleEnabled: (projectId: string, serviceId: string) => void;
  /** ⋯ メニュー。編集・Finder で表示・複製・登録を解除（決定 i） */
  onOpenProjectMenu: (projectId: string) => void;
  onRestartService: (serviceId: string) => void;
  onKeepWaiting: () => void;
  onAbortStart: () => void;
  onCancelSwitch: () => void;
  onInspectBlocker: () => void;
  onDismissSheet: () => void;
  onRetry: () => void;
  onKillHolder: () => void;
  onCopyPid: (pid: number) => void;
  onForceStop: () => void;
  onAdopt: () => void;
  onStopAll: () => void;
  onExpoModeChange: (mode: ExpoMode) => void;
  onCopyExpoUrl: () => void;
  onOpenIOS: () => void;
  onOpenAndroid: () => void;
  onWizardStep: (step: number) => void;
  wizard: React.ReactNode;
}

export function MainWindow(props: MainWindowProps) {
  const { projects, phase, sheet, selection, serviceStates } = props;
  const byId = useCallback(
    (id: string) => projects.find((p) => p.id === id) ?? null,
    [projects],
  );

  const activeId = phase.kind === "idle" ? null : phase.projectId;
  const active = activeId ? byId(activeId) : null;
  const busy = phase.kind === "starting" || phase.kind === "stopping" || phase.kind === "stalled";

  const statusLabel =
    phase.kind === "starting"
      ? "起動中…"
      : phase.kind === "stalled"
        ? `起動中 · ${phase.elapsedSec}秒`
        : phase.kind === "stopping"
          ? "停止中…"
          : phase.kind === "running"
            ? `稼働中 · ${props.elapsedLabel}`
            : "停止中";

  const tone: StatusTone = busy
    ? "busy"
    : active && isDegraded(active, serviceStates)
      ? "warn"
      : active
        ? "running"
        : "stopped";

  const selected = useMemo(() => {
    const p = byId(selection.projectId);
    if (!p) return null;
    if (selection.kind === "project") return { project: p, service: null };
    const s = p.services.find((x) => x.id === selection.serviceId) ?? p.services[0] ?? null;
    return { project: p, service: s };
  }, [byId, selection]);

  let banner: React.ReactNode = null;
  if (selected?.service) {
    const svc = selected.service;
    if (phase.kind === "stalled" && svc.id === phase.serviceId) {
      banner = (
        <StallBanner
          elapsedSec={phase.elapsedSec}
          port={svc.ports[0]?.port ?? 0}
          onKeepWaiting={props.onKeepWaiting}
          onAbort={props.onAbortStart}
        />
      );
    } else if (
      selected.project.id === activeId &&
      /* 対象外のサービスには警告を出さない。落ちたのではなく最初から起動していない（決定 h） */
      isEnabled(selected.project, svc) &&
      svc.failurePolicy === "continue" &&
      (serviceStates[svc.id] ?? "stopped") !== "running"
    ) {
      banner = <DegradedBanner onRestart={() => props.onRestartService(svc.id)} />;
    }
  }

  return (
    <div className="mac">
      <div className="win2">
        <Toolbar
          project={active}
          statusLabel={statusLabel}
          tone={tone}
          busy={busy}
          onOpenBrowser={props.onOpenBrowser}
          onOpenEditor={props.onOpenEditor}
          onStop={props.onStop}
        />

        <div className="w2body">
          <Sidebar
            projects={projects}
            activeId={activeId}
            selection={selection}
            serviceStates={serviceStates}
            unreadErrors={props.unreadErrors}
            expanded={props.expanded}
            reverseOrder={props.reverseOrder}
            onSelect={props.onSelect}
            onToggleExpand={props.onToggleExpand}
            onToggleOrder={props.onToggleOrder}
            onAddProject={props.onAddProject}
            onOpenSettings={props.onOpenSettings}
          />

          {selected?.service ? (
            <ServiceDetail
              service={selected.service}
              state={serviceStates[selected.service.id] ?? "stopped"}
              isActive={selected.project.id === activeId}
              lines={props.logs[selected.service.id] ?? []}
              follow={props.follow}
              inspectorOpen={props.inspectorOpen}
              banner={banner}
              onToggleInspector={props.onToggleInspector}
              onToggleFollow={props.onToggleFollow}
              onClear={props.onClearLog}
            />
          ) : selected ? (
            <ProjectDetail
              project={selected.project}
              activeProject={active}
              serviceStates={serviceStates}
              onSwitch={() => props.onSwitchTo(selected.project.id)}
              onToggleEnabled={(serviceId) =>
                props.onToggleEnabled(selected.project.id, serviceId)
              }
              onOpenMenu={() => props.onOpenProjectMenu(selected.project.id)}
            />
          ) : (
            <div className="detail" />
          )}

          {props.inspectorOpen && selected?.service && isExpoService(selected.service.name) && (
            <ExpoInspector
              url={props.expo.url}
              qr={props.expo.qr}
              mode={props.expo.mode}
              reachability={props.expo.reachability}
              onModeChange={props.onExpoModeChange}
              onCopyUrl={props.onCopyExpoUrl}
              onOpenIOS={props.onOpenIOS}
              onOpenAndroid={props.onOpenAndroid}
              onClose={props.onToggleInspector}
            />
          )}
        </div>

        {/* 不変条件 1: シートが出ている間、サイドバーはこのスクリムの下 */}
        {sheet.kind !== "none" && (
          <div className="scrim">
            <div className={sheet.kind === "wizard" ? "sheet sheet-w" : "sheet"}>
              {sheet.kind === "switching" && byId(sheet.fromId) && byId(sheet.toId) && (
                <TransitionSheet
                  from={byId(sheet.fromId)!}
                  to={byId(sheet.toId)!}
                  step={sheet.step}
                  observed={props.observed}
                  onCancel={props.onCancelSwitch}
                  onInspectBlocker={props.onInspectBlocker}
                />
              )}
              {sheet.kind === "failed" && (
                <ErrorSheet
                  error={sheet.error}
                  onClose={props.onDismissSheet}
                  onRetry={props.onRetry}
                  onKillHolder={props.onKillHolder}
                  onCopyPid={props.onCopyPid}
                  onForceStop={props.onForceStop}
                  onOpenServiceLog={(serviceId) => {
                    // シートを閉じてから、落ちたサービスを選択した状態にする
                    props.onDismissSheet();
                    if (activeId) props.onSelect({ kind: "service", projectId: activeId, serviceId });
                  }}
                />
              )}
              {sheet.kind === "adopt" && (
                <AdoptSheet
                  found={sheet.found}
                  projectName={
                    sheet.guessedProjectId ? byId(sheet.guessedProjectId)?.name ?? null : null
                  }
                  onAdopt={props.onAdopt}
                  onStopAll={props.onStopAll}
                  onIgnore={props.onDismissSheet}
                />
              )}
              {sheet.kind === "wizard" && props.wizard}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/* ============================================================
   Menu bar popover (v2)
   ここだけ「行クリック＝即実行」。速さのための面なので作法を変える。
   ============================================================ */

export function MenuBarPopover({
  projects,
  activeId,
  serviceStates,
  elapsedLabel,
  onSwitchTo,
  onStop,
  onOpenBrowser,
  onOpenEditor,
  onOpenWindow,
  onOpenSettings,
}: {
  projects: Project[];
  activeId: string | null;
  serviceStates: Record<string, ServiceState>;
  elapsedLabel: string;
  onSwitchTo: (projectId: string) => void;
  onStop: () => void;
  onOpenBrowser: () => void;
  onOpenEditor: () => void;
  onOpenWindow: () => void;
  onOpenSettings: () => void;
}) {
  const active = activeId ? projects.find((p) => p.id === activeId) ?? null : null;

  return (
    <div className="mac">
      <div className="popwrap">
        <span className="pop-arrow" />
        <div className="pop">
          {active && (
            <div className="pop-active">
              <div className="pop-top">
                <ProjectChip project={active} />
                <span className="pop-name">{active.name}</span>
                <span className="pop-state">
                  稼働中 {elapsedLabel}
                  <StatusDot tone={isDegraded(active, serviceStates) ? "warn" : "running"} />
                </span>
              </div>
              {/* 対象外のサービスはここに出さない。動かしていないものを並べても意味がない。 */}
              <div className="pop-dots">
                {enabledServices(active).map((s) => (
                  <span className="sv" key={s.id}>
                    <StatusDot tone={toneOf(serviceStates[s.id] ?? "stopped")} />
                    {s.name}
                  </span>
                ))}
              </div>
              <div className="pop-acts">
                <button className="btn" onClick={onOpenBrowser}>
                  <ExternalIcon />
                  開く
                </button>
                <button className="btn" onClick={onOpenEditor}>
                  <CodeIcon />
                  Cursor
                </button>
                <span className="spacer" />
                <button className="btn danger" onClick={onStop}>
                  <StopIcon />
                  停止
                </button>
              </div>
            </div>
          )}

          <div className="hair" />
          <div className="pop-sec">{active ? "切り替え" : "プロジェクト"}</div>
          <div className="pop-list">
            {projects
              .filter((p) => p.id !== activeId)
              .map((p) => (
                <div key={p.id} className="pop-item" onClick={() => onSwitchTo(p.id)}>
                  <ProjectChip project={p} small />
                  <span className="nm">{p.name}</span>
                  <span className="tw">{p.lastUsedLabel}</span>
                </div>
              ))}
          </div>

          <div className="hair" />
          <div className="pop-foot">
            <button className="fbtn" onClick={onOpenWindow}>
              <SwapIcon />
              ウィンドウを開く
            </button>
            <span className="spacer" />
            <button className="fbtn" aria-label="設定" onClick={onOpenSettings}>
              <GearIcon />
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   Icons — ネイティブ実装では NSImage(systemSymbolName:) に置き換える
   ============================================================ */

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

const CheckIcon = () => (
  <svg className="tick ok" viewBox="0 0 24 24" strokeWidth={3.4} {...stroke}>
    <path d="M20 6L9 17l-5-5" />
  </svg>
);
const CircleIcon = () => (
  <svg className="tick wait" viewBox="0 0 24 24" strokeWidth={2.4} {...stroke}>
    <circle cx="12" cy="12" r="8" />
  </svg>
);
const LockIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2.2} {...stroke}>
    <path d="M7 11V7a5 5 0 0 1 10 0v4" />
    <rect x="4.5" y="11" width="15" height="10" rx="2.2" />
  </svg>
);
const WarnIcon = () => (
  <svg width="15" height="15" viewBox="0 0 24 24" strokeWidth={2.1} {...stroke}>
    <path d="M10.3 3.9L1.9 18a2 2 0 0 0 1.7 3h16.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
    <path d="M12 9v4.5M12 17.2h.01" />
  </svg>
);
const ExternalIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2.1} {...stroke}>
    <path d="M15 3h6v6M20 4l-9.5 9.5" />
    <path d="M19 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5" />
  </svg>
);
const CodeIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2.2} {...stroke}>
    <path d="M9 18l-6-6 6-6M15 6l6 6-6 6" />
  </svg>
);
const DocIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2} {...stroke}>
    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
    <path d="M14 2v6h6M8 13h8M8 17h5" />
  </svg>
);
const StopIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor">
    <rect x="5.5" y="5.5" width="13" height="13" rx="2.2" />
  </svg>
);
const SwapIcon = () => (
  <svg width="12" height="12" viewBox="0 0 24 24" strokeWidth={2.2} {...stroke}>
    <path d="M4 8h13l-3.2-3.2M20 16H7l3.2 3.2" />
  </svg>
);
const PlusIcon = () => (
  <svg width="13" height="13" viewBox="0 0 24 24" strokeWidth={2.2} {...stroke}>
    <path d="M12 5v14M5 12h14" />
  </svg>
);
const GearIcon = () => (
  <svg width="13" height="13" viewBox="0 0 24 24" strokeWidth={1.9} {...stroke}>
    <circle cx="12" cy="12" r="3.4" />
    <circle cx="12" cy="12" r="8.4" />
    <path d="M12 3.6v2.2M12 18.2v2.2M3.6 12h2.2M18.2 12h2.2M6.1 6.1l1.5 1.5M16.4 16.4l1.5 1.5M17.9 6.1l-1.5 1.5M7.6 16.4l-1.5 1.5" />
  </svg>
);
const ChevronDownIcon = () => (
  <svg width="9" height="9" viewBox="0 0 24 24" strokeWidth={3} {...stroke}>
    <path d="M6 9l6 6 6-6" />
  </svg>
);
const TriangleIcon = () => (
  <svg width="8" height="8" viewBox="0 0 24 24" fill="currentColor">
    <path d="M8 4l10 8-10 8z" />
  </svg>
);
const UpDownIcon = () => (
  <svg width="9" height="9" viewBox="0 0 24 24" strokeWidth={2.6} {...stroke}>
    <path d="M7 15l-3 3-3-3M4 18V6M17 9l3-3 3 3M20 6v12" />
  </svg>
);
const QRIcon = () => (
  <svg width="12" height="12" viewBox="0 0 24 24" strokeWidth={2} {...stroke}>
    <rect x="3" y="3" width="7" height="7" rx="1" />
    <rect x="14" y="3" width="7" height="7" rx="1" />
    <rect x="3" y="14" width="7" height="7" rx="1" />
    <path d="M14 14h3v3h-3zM20 14h1M14 20h3M20 17v4" />
  </svg>
);
const SearchIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2.4} {...stroke}>
    <circle cx="10.5" cy="10.5" r="6.5" />
    <path d="M20 20l-4.7-4.7" />
  </svg>
);
const TrashIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2} {...stroke}>
    <path d="M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M6 7l1 13a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-13" />
  </svg>
);
const CopyIcon = () => (
  <svg width="11" height="11" viewBox="0 0 24 24" strokeWidth={2} {...stroke}>
    <rect x="9" y="9" width="12" height="12" rx="2" />
    <path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1" />
  </svg>
);
const RestoreIcon = () => (
  <svg width="15" height="15" viewBox="0 0 24 24" strokeWidth={2.1} {...stroke}>
    <path d="M3 12a9 9 0 1 0 2.6-6.4" />
    <path d="M3 4v5h5" />
  </svg>
);
const EllipsisIcon = () => (
  <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor">
    <circle cx="5" cy="12" r="1.8" />
    <circle cx="12" cy="12" r="1.8" />
    <circle cx="19" cy="12" r="1.8" />
  </svg>
);

/* ============================================================
   Sample data
   ============================================================ */

export const SAMPLE_PROJECTS: Project[] = [
  {
    id: "bell",
    name: "Bell",
    initial: "B",
    color: "#0A84FF",
    directory: "~/Documents/GitHub/bellcierge-phase2-web",
    lastUsedLabel: "たった今",
    // 今日は Expo を使わない、という状態の例
    enabledNow: { "bell-expo": false },
    services: [
      {
        id: "bell-supabase",
        name: "Supabase",
        command: "supabase start",
        enabledByDefault: true,
        failurePolicy: "block",
        // 単一ポートではない。ports[0] が代表。
        ports: [
          { label: "API", port: 54321, openUrl: "http://127.0.0.1:54321" },
          { label: "DB", port: 54322 },
          { label: "Studio", port: 54323, openUrl: "http://127.0.0.1:54323" },
          { label: "Inbucket", port: 54324, openUrl: "http://127.0.0.1:54324" },
          { label: "Analytics", port: 54327 },
        ],
      },
      {
        id: "bell-web",
        name: "Web",
        command: "pnpm dev",
        enabledByDefault: true,
        failurePolicy: "block",
        ports: [{ port: 3000, openUrl: "http://localhost:3000" }],
      },
      {
        id: "bell-expo",
        name: "Expo",
        command: "pnpm expo start",
        enabledByDefault: true,
        failurePolicy: "continue",
        ports: [{ port: 8081 }],
      },
      {
        id: "bell-inngest",
        name: "Inngest",
        command: "pnpm inngest-cli dev",
        enabledByDefault: true,
        failurePolicy: "continue",
        ports: [{ port: 8288, openUrl: "http://localhost:8288" }],
      },
    ],
  },
  {
    id: "penta",
    name: "Penta",
    initial: "P",
    color: "#BF5AF2",
    directory: "~/Documents/GitHub/web-penta",
    lastUsedLabel: "3時間前",
    services: [
      {
        id: "penta-docker",
        name: "Docker",
        command: "docker compose up",
        enabledByDefault: true,
        failurePolicy: "block",
        ports: [{ label: "Postgres", port: 5432 }],
      },
      {
        id: "penta-web",
        name: "Web",
        command: "pnpm dev",
        enabledByDefault: true,
        failurePolicy: "block",
        ports: [{ port: 3000, openUrl: "http://localhost:3000" }],
      },
      {
        id: "penta-native",
        name: "Native",
        command: "pnpm expo start",
        enabledByDefault: true,
        failurePolicy: "continue",
        ports: [{ port: 8081 }],
      },
    ],
  },
];

/** 起動時に観測した listen ポートの例。ゲート検証1はこれを使う（設定値ではない）。 */
export const SAMPLE_OBSERVED: ObservedPorts = {
  "bell-supabase": [54321, 54322, 54323, 54324, 54327],
  "bell-web": [3000],
  "bell-inngest": [8288],
  // bell-expo は対象外なので観測されていない
};

export const SAMPLE_LOGS: Record<string, LogLine[]> = {
  "bell-web": [
    { ts: "14:31:20", level: "info", text: "▲ Next.js 15.4.2" },
    { ts: "14:31:22", level: "info", text: "✓ Ready in 1.4s" },
    { ts: "14:33:12", level: "warn", text: "⚠ Fast Refresh had to perform a full reload" },
    {
      ts: "14:33:41",
      level: "error",
      text: "✕ TypeError: Cannot read properties of undefined (reading 'id')",
    },
  ],
};
