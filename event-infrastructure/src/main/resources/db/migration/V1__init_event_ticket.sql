CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE SCHEMA IF NOT EXISTS event_ticket;
SET search_path TO event_ticket, public;

CREATE TYPE event_status AS ENUM ('DRAFT','PENDING_REVIEW','PUBLISHED','HIDDEN','REJECTED','CANCELLED','COMPLETED');
CREATE TYPE ticket_kind AS ENUM ('GENERAL_ADMISSION','ASSIGNED_SEAT');
CREATE TYPE invitation_status AS ENUM ('PENDING','ACCEPTED','REVOKED','EXPIRED');
CREATE TYPE ticket_status AS ENUM ('VALID','CHECKED_IN','VOID','REFUNDED');
CREATE TABLE users_projection
(
    user_id        uuid PRIMARY KEY,
    email          citext      NOT NULL,
    display_name   varchar(160),
    active         boolean     NOT NULL DEFAULT true,
    source_version bigint      NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE categories
(
    id        uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    name      varchar(100) NOT NULL UNIQUE,
    slug      varchar(120) NOT NULL UNIQUE,
    is_active boolean      NOT NULL DEFAULT true
);
CREATE TABLE venues
(
    id           uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    name         varchar(200) NOT NULL,
    address_line text         NOT NULL,
    city         varchar(120),
    country_code char(2)      NOT NULL DEFAULT 'VN',
    timezone     varchar(64)  NOT NULL DEFAULT 'Asia/Ho_Chi_Minh'
);
CREATE TABLE seat_maps
(
    id       uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    venue_id uuid         NOT NULL REFERENCES venues (id),
    name     varchar(160) NOT NULL,
    version  integer      NOT NULL CHECK (version > 0),
    layout   jsonb        NOT NULL DEFAULT '{}'::jsonb,
    active   boolean      NOT NULL DEFAULT true,
    UNIQUE (venue_id, name, version)
);
CREATE TABLE seat_sections
(
    id          uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    seat_map_id uuid         NOT NULL REFERENCES seat_maps (id) ON DELETE CASCADE,
    code        varchar(40)  NOT NULL,
    name        varchar(120) NOT NULL,
    sort_order  integer      NOT NULL DEFAULT 0,
    UNIQUE (seat_map_id, code)
);
CREATE TABLE seats
(
    id           uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    section_id   uuid        NOT NULL REFERENCES seat_sections (id) ON DELETE CASCADE,
    row_label    varchar(24) NOT NULL,
    seat_label   varchar(24) NOT NULL,
    x_coordinate numeric(10, 2),
    y_coordinate numeric(10, 2),
    accessible   boolean     NOT NULL DEFAULT false,
    UNIQUE (section_id, row_label, seat_label)
);
CREATE TABLE events
(
    id                    uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    organizer_id          uuid         NOT NULL,
    venue_id              uuid         NOT NULL REFERENCES venues (id),
    category_id           uuid REFERENCES categories (id),
    title                 varchar(240) NOT NULL,
    slug                  varchar(260) NOT NULL UNIQUE,
    description           text         NOT NULL,
    starts_at             timestamptz  NOT NULL,
    ends_at               timestamptz  NOT NULL,
    sales_start_at        timestamptz  NOT NULL,
    sales_end_at          timestamptz  NOT NULL,
    status                event_status NOT NULL DEFAULT 'DRAFT',
    configuration_version integer      NOT NULL DEFAULT 1,
    published_at          timestamptz,
    created_at            timestamptz  NOT NULL DEFAULT now(),
    updated_at            timestamptz  NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    CHECK (sales_end_at > sales_start_at AND sales_end_at <= starts_at)
);
CREATE INDEX events_listing_idx ON events (status, sales_start_at, starts_at) WHERE status = 'PUBLISHED';
CREATE TABLE event_media
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    event_id    uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    storage_key text        NOT NULL UNIQUE,
    media_type  varchar(30) NOT NULL,
    alt_text    varchar(300),
    sort_order  integer     NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE event_moderation_history
(
    id              uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    event_id        uuid         NOT NULL REFERENCES events (id),
    action          varchar(40)  NOT NULL,
    previous_status event_status,
    new_status      event_status NOT NULL,
    note            text,
    acted_by        uuid,
    acted_at        timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX event_moderation_history_idx ON event_moderation_history (event_id, acted_at DESC);
CREATE TABLE ticket_types
(
    id            uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    event_id      uuid           NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    seat_map_id   uuid REFERENCES seat_maps (id),
    name          varchar(120)   NOT NULL,
    kind          ticket_kind    NOT NULL,
    currency      char(3)        NOT NULL,
    unit_price    numeric(14, 2) NOT NULL CHECK (unit_price >= 0),
    capacity      integer CHECK (capacity >= 0),
    sale_start_at timestamptz,
    sale_end_at   timestamptz,
    max_per_order integer        NOT NULL DEFAULT 10 CHECK (max_per_order > 0),
    active        boolean        NOT NULL DEFAULT true,
    UNIQUE (event_id, name),
    UNIQUE (id, event_id),
    CHECK ((kind = 'GENERAL_ADMISSION' AND seat_map_id IS NULL AND capacity IS NOT NULL) OR
           (kind = 'ASSIGNED_SEAT' AND seat_map_id IS NOT NULL AND capacity IS NULL))
);
CREATE TABLE event_seat_configuration
(
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id       uuid    NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    seat_id        uuid    NOT NULL REFERENCES seats (id),
    ticket_type_id uuid    NOT NULL,
    blocked        boolean NOT NULL DEFAULT false,
    UNIQUE (event_id, seat_id),
    FOREIGN KEY (ticket_type_id, event_id) REFERENCES ticket_types (id, event_id)
);
CREATE TABLE staff_invitations
(
    id                     uuid PRIMARY KEY           DEFAULT gen_random_uuid(),
    event_id               uuid              NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    invited_email          citext            NOT NULL,
    token_hash             bytea             NOT NULL UNIQUE,
    token_ciphertext       bytea             NOT NULL,
    encryption_key_version varchar(64)       NOT NULL,
    invited_by             uuid              NOT NULL,
    status                 invitation_status NOT NULL DEFAULT 'PENDING',
    expires_at             timestamptz       NOT NULL,
    accepted_by            uuid,
    created_at             timestamptz       NOT NULL DEFAULT now(),
    accepted_at            timestamptz,
    UNIQUE (event_id, invited_email),
    CHECK (expires_at > created_at)
);
CREATE TABLE staff_invitation_ticket_types
(
    invitation_id  uuid NOT NULL REFERENCES staff_invitations (id) ON DELETE CASCADE,
    ticket_type_id uuid NOT NULL REFERENCES ticket_types (id),
    PRIMARY KEY (invitation_id, ticket_type_id)
);
CREATE TABLE event_staff
(
    event_id    uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL,
    invited_by  uuid        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    accepted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, user_id)
);
CREATE TABLE event_staff_ticket_types
(
    event_id       uuid NOT NULL,
    user_id        uuid NOT NULL,
    ticket_type_id uuid NOT NULL REFERENCES ticket_types (id),
    PRIMARY KEY (event_id, user_id, ticket_type_id),
    FOREIGN KEY (event_id, user_id) REFERENCES event_staff (event_id, user_id) ON DELETE CASCADE
);
CREATE TABLE tickets
(
    id                     uuid PRIMARY KEY        DEFAULT gen_random_uuid(),
    commerce_order_id      uuid           NOT NULL,
    commerce_order_item_id uuid           NOT NULL,
    source_ticket_index    smallint       NOT NULL CHECK (source_ticket_index > 0),
    event_id               uuid           NOT NULL REFERENCES events (id),
    ticket_type_id         uuid           NOT NULL REFERENCES ticket_types (id),
    external_seat_id       uuid,
    holder_user_id         uuid           NOT NULL,
    ticket_type_name       varchar(120)   NOT NULL,
    unit_price             numeric(14, 2) NOT NULL CHECK (unit_price >= 0),
    currency               char(3)        NOT NULL,
    holder_name            varchar(160),
    holder_email           citext,
    qr_token_hash          bytea          NOT NULL UNIQUE,
    qr_token_ciphertext    bytea          NOT NULL,
    qr_key_version         varchar(64)    NOT NULL,
    status                 ticket_status  NOT NULL DEFAULT 'VALID',
    issued_at              timestamptz    NOT NULL DEFAULT now(),
    checked_in_at          timestamptz,
    voided_at              timestamptz,
    UNIQUE (commerce_order_item_id, source_ticket_index),
    UNIQUE (event_id, external_seat_id),
    FOREIGN KEY (ticket_type_id, event_id) REFERENCES ticket_types (id, event_id)
);
CREATE INDEX tickets_scan_idx ON tickets (event_id, status);
CREATE INDEX tickets_holder_idx ON tickets (holder_user_id, issued_at DESC);
CREATE TABLE checkin_attempts
(
    id               uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    ticket_id        uuid        NOT NULL REFERENCES tickets (id),
    event_id         uuid        NOT NULL REFERENCES events (id),
    scanned_by       uuid,
    accepted         boolean     NOT NULL,
    rejection_reason varchar(80),
    device_id        varchar(120),
    scanned_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (accepted OR rejection_reason IS NOT NULL)
);
CREATE INDEX checkin_attempt_event_idx ON checkin_attempts (event_id, scanned_at DESC);
CREATE TABLE inbox_messages
(
    event_id     uuid PRIMARY KEY,
    event_type   varchar(160) NOT NULL,
    occurred_at  timestamptz  NOT NULL,
    payload      jsonb        NOT NULL,
    processed_at timestamptz  NOT NULL DEFAULT now()
);
CREATE TABLE idempotency_keys
(
    id              uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    actor_id        uuid,
    operation       varchar(120) NOT NULL,
    idempotency_key varchar(255) NOT NULL,
    request_hash    bytea        NOT NULL,
    response_status smallint,
    response_body   jsonb,
    resource_id     uuid,
    expires_at      timestamptz  NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (actor_id, operation, idempotency_key),
    CHECK (expires_at > created_at)
);
CREATE TABLE integration_outbox
(
    id             uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    aggregate_id   uuid         NOT NULL,
    aggregate_type varchar(100) NOT NULL,
    event_type     varchar(160) NOT NULL,
    payload        jsonb        NOT NULL,
    headers        jsonb        NOT NULL DEFAULT '{}'::jsonb,
    occurred_at    timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX outbox_occurred_idx ON integration_outbox (occurred_at);
CREATE TABLE audit_log
(
    id          uuid PRIMARY KEY      DEFAULT gen_random_uuid(),
    actor_id    uuid,
    action      varchar(120) NOT NULL,
    entity_type varchar(80)  NOT NULL,
    entity_id   uuid,
    before_data jsonb,
    after_data  jsonb,
    occurred_at timestamptz  NOT NULL DEFAULT now(),
    request_id  uuid
);
CREATE INDEX audit_log_entity_idx ON audit_log (entity_type, entity_id, occurred_at DESC);
CREATE FUNCTION set_updated_at() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    NEW.updated_at := now(); RETURN NEW;
END;
$$;
CREATE TRIGGER events_updated_at
    BEFORE UPDATE
    ON events
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
