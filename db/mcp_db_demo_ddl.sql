-- mcp_db_demo_ddl.sql: the hotel demo's tables, views, sequences and routines, for MCPDBWizard
-- for MariaDB. Run it as mcpdemo, after mcp_db_demo_user.sql:
--
--   mariadb -h <host> -u mcpdemo -p mcpdemo < db/mcp_db_demo_ddl.sql
--
-- A port of the Oracle demo in github.com/srmadscience/mcpdbwizard-demo, in MariaDB's default
-- sql_mode. Oracle's packages become routines named <package>_<member>: ROOM_MANAGER.BookRoom is
-- room_manager_bookroom, CUSTOMER_PORTAL.my_bookings is customer_portal_my_bookings.
--
-- What changed on the way from Oracle:
-- * VARCHAR2(n) -> varchar(n); NUMBER(p,s) -> decimal(p,s); DATE -> datetime; NATURAL -> int
--   unsigned; SYSDATE -> now(); DECODE -> IF.
-- * SYS_CONTEXT('MCP', 'CUSTOMER_NAME') -> the user variable @mcp_customer_name, which
--   MCPDBWizard for MariaDB sets for each tool call from the ?CUSTOMER_NAME= URL parameter.
--   Nothing needs installing in the database for it. Unset reads NULL, so every customer_portal
--   routine refuses a call without it.
-- * USE MARIADB 12.3 OR LATER. A REF CURSOR output (hotel_occupancy, room_manager_getroomlist,
--   room_manager_bookroom, customer_portal_my_bookings, customer_portal_my_complaints) is a
--   SYS_REFCURSOR from 12.3; on 11.4 and 11.8 those routines are created as
--   placeholders that return the text '<cursor name> substitute', and replaced on 12.3+.
-- * Oracle's '' is NULL, so a trimmed input goes through nullif(..., '') before a NULL test.

-- ---------------------------------------------------------------- tables
CREATE TABLE hotels (
    hotel_name      varchar(20)  NOT NULL,
    region_name     varchar(20)  NOT NULL,
    star_rating     decimal(1,0) NOT NULL,
    customer_rating decimal(2,1) NOT NULL,
    CONSTRAINT hotels_pk PRIMARY KEY (hotel_name)
);

CREATE TABLE hotel_amenities (
    hotel_name          varchar(20)  NOT NULL,
    amenity_name        varchar(80)  NOT NULL,
    amenity_description varchar(200) NOT NULL,
    chargable_y_or_n    varchar(1)   NOT NULL,
    CONSTRAINT hotel_amenities_pk PRIMARY KEY (hotel_name, amenity_name),
    CONSTRAINT hotel_amenities_chk1 CHECK (chargable_y_or_n IN ('Y', 'N')),
    CONSTRAINT hotel_amenities_chk2 CHECK (cast(amenity_name AS binary) = cast(upper(amenity_name) AS binary)),
    CONSTRAINT hotel_amenities_fk1 FOREIGN KEY (hotel_name) REFERENCES hotels (hotel_name) ON DELETE CASCADE
);
CREATE INDEX hotel_amenities_amenity_name ON hotel_amenities (amenity_name);

CREATE TABLE hotel_rooms (
    hotel_name            varchar(20)  NOT NULL,
    room_number           decimal(5,0) NOT NULL,
    room_special_features varchar(200),
    CONSTRAINT hotel_rooms_pk PRIMARY KEY (hotel_name, room_number),
    CONSTRAINT hotel_rooms_fk1 FOREIGN KEY (hotel_name) REFERENCES hotels (hotel_name) ON DELETE CASCADE
);
CREATE INDEX hotel_rooms_room_idx ON hotel_rooms (room_number);

CREATE TABLE customers (
    customer_name varchar(20) NOT NULL,
    phone_number  varchar(20) NOT NULL,
    email_address varchar(80) NOT NULL,
    CONSTRAINT customers_pk PRIMARY KEY (customer_name),
    CONSTRAINT customers_email_has_at CHECK (instr(email_address, '@') > 1 AND instr(email_address, '@') < length(email_address))
);
CREATE UNIQUE INDEX customers_email_address ON customers (email_address);
CREATE UNIQUE INDEX customers_phone_number ON customers (phone_number);

CREATE TABLE room_bookings (
    booking_id    decimal(65,27) NOT NULL COMMENT 'oracle: NUMBER',
    hotel_name    varchar(30)    NOT NULL,
    customer_name varchar(20)    NOT NULL,
    room_number   decimal(5,0)   NOT NULL COMMENT 'oracle: NUMBER(*,0); decimal(5,0) to match hotel_rooms, see the header',
    start_date    datetime       NOT NULL COMMENT 'oracle: DATE',
    end_date      datetime       NOT NULL COMMENT 'oracle: DATE',
    CONSTRAINT room_bookings_pk PRIMARY KEY (booking_id),
    CONSTRAINT start_before_end CHECK (start_date < end_date),
    CONSTRAINT room_bookings_start_midnight CHECK (start_date = cast(start_date AS date)),
    CONSTRAINT room_bookings_end_midnight CHECK (end_date = cast(end_date AS date)),
    CONSTRAINT room_bookings_hotel_room FOREIGN KEY (hotel_name, room_number)
        REFERENCES hotel_rooms (hotel_name, room_number) ON DELETE CASCADE,
    CONSTRAINT room_bookings_fk1 FOREIGN KEY (hotel_name) REFERENCES hotels (hotel_name),
    CONSTRAINT room_bookings_fk2 FOREIGN KEY (customer_name) REFERENCES customers (customer_name)
);
CREATE INDEX room_bookings_customer ON room_bookings (customer_name);
CREATE INDEX room_bookings_hotel_name ON room_bookings (hotel_name);

CREATE SEQUENCE complaint_id_seq;
CREATE TABLE complaints (
    complaint_id    decimal(65,27) DEFAULT (NEXT VALUE FOR complaint_id_seq) NOT NULL COMMENT 'oracle: NUMBER DEFAULT complaint_id_seq.NEXTVAL',
    customer_name   varchar(20)    NOT NULL,
    complaint_date  datetime       DEFAULT current_timestamp NOT NULL COMMENT 'oracle: DATE DEFAULT SYSDATE',
    complaint_text  varchar(400)   NOT NULL,
    resolved_y_or_n varchar(1)     DEFAULT 'N' NOT NULL,
    CONSTRAINT complaints_pk PRIMARY KEY (complaint_id),
    CONSTRAINT complaints_chk1 CHECK (resolved_y_or_n IN ('Y', 'N')),
    CONSTRAINT complaints_fk1 FOREIGN KEY (customer_name) REFERENCES customers (customer_name)
);
CREATE INDEX complaints_customer_name ON complaints (customer_name);

CREATE VIEW hotel_regions (region_name, min_star_rating, max_star_rating, min_customer_rating,
                           customer_star_rating, hotels_in_region) AS
SELECT region_name, min(star_rating), max(star_rating), min(customer_rating), max(customer_rating), count(*)
FROM hotels
GROUP BY region_name;

CREATE VIEW hotel_amenities_summary (amenity_name, percent_time_chargable, hotels_with_amenity) AS
SELECT amenity_name, (sum(IF(chargable_y_or_n = 'Y', 1, 0)) / count(*)) * 100, count(*)
FROM hotel_amenities
GROUP BY amenity_name;

CREATE SEQUENCE booking_id_seq MINVALUE 1 MAXVALUE 9223372036854775806 INCREMENT BY 1 START WITH 10000 CACHE 20 NOCYCLE;

DELIMITER //

-- ---------------------------------------------------------------- upsert_customer
CREATE PROCEDURE upsert_customer(IN  p_customer ROW TYPE OF customers
                                ,OUT p_message  varchar(4000) /* oracle: VARCHAR2 */)
main: BEGIN
  DECLARE c_needs_at varchar(100) DEFAULT ' is not a valid email address, it needs an @ with text on both sides';
  DECLARE v_customer ROW TYPE OF customers;
  DECLARE v_existing ROW TYPE OF customers;
  DECLARE v_found boolean DEFAULT TRUE;
  DECLARE v_err text;

  DECLARE EXIT HANDLER FOR 1062
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    IF instr(v_err, 'customers_email_address') > 0 THEN
      SET p_message = concat('Email address ', v_customer.email_address, ' already belongs to another customer');
    ELSEIF instr(v_err, 'customers_phone_number') > 0 THEN
      SET p_message = concat('Phone number ', v_customer.phone_number, ' already belongs to another customer');
    ELSE
      SET p_message = 'This customer already exists';
    END IF;
  END;
  DECLARE EXIT HANDLER FOR 1205
    SET p_message = concat('Customer ', v_customer.customer_name, ' is being changed by someone else, please try again');
  DECLARE EXIT HANDLER FOR 4025
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
    IF instr(v_err, 'customers_email_has_at') > 0 THEN
      SET p_message = concat('Email address ', v_customer.email_address, c_needs_at);
    ELSE
      RESIGNAL;
    END IF;
  END;

  SET v_customer.customer_name = nullif(upper(trim(p_customer.customer_name)), '');
  SET v_customer.email_address = nullif(lower(trim(p_customer.email_address)), '');
  SET v_customer.phone_number  = nullif(trim(p_customer.phone_number), '');

  IF v_customer.customer_name IS NULL THEN
    SET p_message = 'A customer name is required';
    LEAVE main;
  END IF;
  IF v_customer.phone_number IS NULL THEN
    SET p_message = 'A phone number is required';
    LEAVE main;
  END IF;
  IF v_customer.email_address IS NULL THEN
    SET p_message = 'An email address is required';
    LEAVE main;
  END IF;
  IF instr(v_customer.email_address, '@') <= 1
     OR instr(v_customer.email_address, '@') = length(v_customer.email_address) THEN
    SET p_message = concat('Email address ', v_customer.email_address, c_needs_at);
    LEAVE main;
  END IF;

  BEGIN
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = FALSE;
    SET STATEMENT innodb_lock_wait_timeout = 0 FOR
      SELECT * INTO v_existing FROM customers WHERE customer_name = v_customer.customer_name FOR UPDATE;
  END;
  IF NOT v_found THEN
    INSERT INTO customers (customer_name, phone_number, email_address)
    VALUES (v_customer.customer_name, v_customer.phone_number, v_customer.email_address);
    COMMIT;
    SET p_message = concat('Created customer ', v_customer.customer_name);
    LEAVE main;
  END IF;

  IF v_existing.phone_number <=> v_customer.phone_number AND v_existing.email_address <=> v_customer.email_address THEN
    SET p_message = 'This customer already exists';
  ELSE
    UPDATE customers
       SET phone_number = v_customer.phone_number, email_address = v_customer.email_address
     WHERE customer_name = v_customer.customer_name;
    COMMIT;
    SET p_message = concat('Updated customer ', v_customer.customer_name);
  END IF;
END//

-- ---------------------------------------------------------------- hotel_occupancy
CREATE PROCEDURE hotel_occupancy(IN  p_from_date  datetime /* oracle: DATE */
                                ,IN  p_to_date    datetime /* oracle: DATE */
                                ,OUT p_results    varchar(4000) /* oracle: SYS_REFCURSOR */
                                ,IN  p_hotel_name varchar(4000) /* oracle: VARCHAR2 */)
BEGIN
  DECLARE v_from_date date DEFAULT cast(p_from_date AS date);
  DECLARE v_to_date date DEFAULT cast(p_to_date AS date);
  DECLARE v_hotel_name varchar(20) DEFAULT nullif(upper(trim(p_hotel_name)), '');
  IF v_from_date IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20001, MESSAGE_TEXT = 'A from date is required';
  END IF;
  IF v_to_date IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20002, MESSAGE_TEXT = 'A to date is required';
  END IF;
  IF v_from_date > v_to_date THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20003, MESSAGE_TEXT = 'The from date must not be after the to date';
  END IF;
  IF v_hotel_name IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hotels WHERE hotel_name = v_hotel_name) THEN
    SET @mdb_msg = concat('There is no hotel called ', v_hotel_name);
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20004, MESSAGE_TEXT = @mdb_msg;
  END IF;
  SET p_results = 'SYS_REFCURSOR substitute';
END//
/*M!120300 CREATE OR REPLACE PROCEDURE hotel_occupancy(IN p_from_date datetime
                                           ,IN p_to_date datetime
                                           ,OUT p_results SYS_REFCURSOR
                                           ,IN p_hotel_name varchar(4000))
BEGIN
  DECLARE v_from_date date DEFAULT cast(p_from_date AS date);
  DECLARE v_to_date date DEFAULT cast(p_to_date AS date);
  DECLARE v_hotel_name varchar(20) DEFAULT nullif(upper(trim(p_hotel_name)), '');
  IF v_from_date IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20001, MESSAGE_TEXT = 'A from date is required';
  END IF;
  IF v_to_date IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20002, MESSAGE_TEXT = 'A to date is required';
  END IF;
  IF v_from_date > v_to_date THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20003, MESSAGE_TEXT = 'The from date must not be after the to date';
  END IF;
  IF v_hotel_name IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hotels WHERE hotel_name = v_hotel_name) THEN
    SET @mdb_msg = concat('There is no hotel called ', v_hotel_name);
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20004, MESSAGE_TEXT = @mdb_msg;
  END IF;
  OPEN p_results FOR
    WITH RECURSIVE c (occupancy_date) AS (
           SELECT v_from_date
           UNION ALL
           SELECT occupancy_date + INTERVAL 1 DAY FROM c WHERE occupancy_date < v_to_date),
         h AS (
           SELECT hotel_name, count(*) AS rooms FROM hotel_rooms
            WHERE v_hotel_name IS NULL OR hotel_name = v_hotel_name
            GROUP BY hotel_name)
    SELECT c.occupancy_date,
           h.hotel_name,
           h.rooms AS rooms_in_hotel,
           count(DISTINCT b.room_number) AS rooms_occupied,
           round(count(DISTINCT b.room_number) / h.rooms * 100, 1) AS percent_occupied
    FROM c CROSS JOIN h
    LEFT JOIN room_bookings b ON b.hotel_name = h.hotel_name AND b.start_date <= c.occupancy_date
                             AND b.end_date > c.occupancy_date
    GROUP BY c.occupancy_date, h.hotel_name, h.rooms
    ORDER BY c.occupancy_date, h.hotel_name;
END */ //

-- ---------------------------------------------------------------- room_manager
CREATE PROCEDURE room_manager_getroomlist(IN  p_hotel_name varchar(4000) /* oracle: VARCHAR2 */
                                         ,IN  p_from_date  datetime /* oracle: DATE */
                                         ,IN  p_to_date    datetime /* oracle: DATE */
                                         ,OUT p_results    varchar(4000) /* oracle: RoomCursor */
                                         ,OUT p_message    varchar(4000) /* oracle: VARCHAR2 */)
BEGIN
  SET p_message = concat_ws('', 'Looking for availability for ', p_hotel_name, p_from_date, ' to ', p_to_date);
  IF nullif(trim(p_hotel_name), '') IS NULL THEN
    SET p_message = 'Hotel Name Needed';
  ELSEIF p_from_date IS NULL THEN
    SET p_message = 'From Date Needed';
  ELSEIF p_to_date IS NULL THEN
    SET p_message = 'To Date Needed';
  ELSE
    SET p_results = 'RoomCursor substitute';
  END IF;
END//
/*M!120300 CREATE OR REPLACE PROCEDURE room_manager_getroomlist(IN p_hotel_name varchar(4000)
                                                    ,IN p_from_date datetime
                                                    ,IN p_to_date datetime
                                                    ,OUT p_results SYS_REFCURSOR
                                                    ,OUT p_message varchar(4000))
BEGIN
  SET p_message = concat_ws('', 'Looking for availability for ', p_hotel_name, p_from_date, ' to ', p_to_date);
  IF nullif(trim(p_hotel_name), '') IS NULL THEN
    SET p_message = 'Hotel Name Needed';
  ELSEIF p_from_date IS NULL THEN
    SET p_message = 'From Date Needed';
  ELSEIF p_to_date IS NULL THEN
    SET p_message = 'To Date Needed';
  ELSE
    OPEN p_results FOR
      SELECT r.hotel_name, r.room_number, r.room_special_features
        FROM hotel_rooms r
        LEFT JOIN room_bookings b
          ON b.hotel_name = r.hotel_name AND b.room_number = r.room_number
         AND (   (b.start_date >= p_from_date AND b.end_date <= p_to_date)
              OR (b.start_date <= p_from_date AND b.end_date >= p_to_date)
              OR (b.start_date >= p_from_date AND b.end_date >= p_from_date)
              OR (b.start_date <= p_to_date AND b.end_date >= p_to_date))
       WHERE r.hotel_name = upper(trim(p_hotel_name))
         AND b.booking_id IS NULL
       ORDER BY r.room_number;
  END IF;
END */ //

CREATE PROCEDURE room_manager_bookroom(IN  p_hotel_name    varchar(4000) /* oracle: VARCHAR2 */
                                      ,IN  p_customer_name varchar(4000) /* oracle: VARCHAR2 */
                                      ,IN  p_from_date     datetime /* oracle: DATE */
                                      ,IN  p_to_date       datetime /* oracle: DATE */
                                      ,IN  p_room_count    int unsigned /* oracle: NATURAL */
                                      ,OUT BookingCursor   varchar(4000) /* oracle: BookingCursor */
                                      ,OUT p_message       varchar(4000) /* oracle: VARCHAR2 */)
BEGIN
  DECLARE l_booked_room_count int DEFAULT 0;
  DECLARE l_room_number decimal(5,0);
  DECLARE l_done boolean DEFAULT FALSE;
  DECLARE free_rooms CURSOR FOR
    SELECT r.room_number FROM hotel_rooms r
     WHERE r.hotel_name = upper(trim(p_hotel_name))
       AND NOT EXISTS (SELECT NULL FROM room_bookings b
                        WHERE b.hotel_name = r.hotel_name AND b.room_number = r.room_number
                          AND (   (b.start_date >= p_from_date AND b.end_date <= p_to_date)
                               OR (b.start_date <= p_from_date AND b.end_date >= p_to_date)
                               OR (b.start_date >= p_from_date AND b.end_date >= p_from_date)
                               OR (b.start_date <= p_to_date AND b.end_date >= p_to_date)))
     ORDER BY r.room_number;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET l_done = TRUE;
  IF @@in_transaction = 0 THEN
    START TRANSACTION;
  END IF;
  OPEN free_rooms;
  rooms: LOOP
    FETCH free_rooms INTO l_room_number;
    IF l_done THEN
      LEAVE rooms;
    END IF;
    INSERT INTO room_bookings (booking_id, hotel_name, customer_name, room_number, start_date, end_date)
    VALUES (NEXT VALUE FOR booking_id_seq, upper(trim(p_hotel_name)), upper(trim(p_customer_name)),
            l_room_number, p_from_date, p_to_date);
    SET l_booked_room_count = l_booked_room_count + 1;
    IF l_booked_room_count = p_room_count THEN
      LEAVE rooms;
    END IF;
  END LOOP;
  CLOSE free_rooms;
  IF l_booked_room_count < p_room_count THEN
    SET p_message = concat('Unable to book ', p_room_count, ' rooms. Only ', l_booked_room_count, ' available. Nothing booked.');
    ROLLBACK;
  ELSE
    SET p_message = concat_ws('', 'Booked ', p_room_count, ' rooms.');
    COMMIT;
  END IF;
  SET BookingCursor = 'BookingCursor substitute';
END//
/*M!120300 CREATE OR REPLACE PROCEDURE room_manager_bookroom(IN p_hotel_name varchar(4000)
                                                 ,IN p_customer_name varchar(4000)
                                                 ,IN p_from_date datetime
                                                 ,IN p_to_date datetime
                                                 ,IN p_room_count int unsigned
                                                 ,OUT BookingCursor SYS_REFCURSOR
                                                 ,OUT p_message varchar(4000))
BEGIN
  DECLARE l_booked_room_count int DEFAULT 0;
  DECLARE l_room_number decimal(5,0);
  DECLARE l_done boolean DEFAULT FALSE;
  DECLARE free_rooms CURSOR FOR
    SELECT r.room_number FROM hotel_rooms r
     WHERE r.hotel_name = upper(trim(p_hotel_name))
       AND NOT EXISTS (SELECT NULL FROM room_bookings b
                        WHERE b.hotel_name = r.hotel_name AND b.room_number = r.room_number
                          AND (   (b.start_date >= p_from_date AND b.end_date <= p_to_date)
                               OR (b.start_date <= p_from_date AND b.end_date >= p_to_date)
                               OR (b.start_date >= p_from_date AND b.end_date >= p_from_date)
                               OR (b.start_date <= p_to_date AND b.end_date >= p_to_date)))
     ORDER BY r.room_number;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET l_done = TRUE;
  IF @@in_transaction = 0 THEN
    START TRANSACTION;
  END IF;
  OPEN free_rooms;
  rooms: LOOP
    FETCH free_rooms INTO l_room_number;
    IF l_done THEN
      LEAVE rooms;
    END IF;
    INSERT INTO room_bookings (booking_id, hotel_name, customer_name, room_number, start_date, end_date)
    VALUES (NEXT VALUE FOR booking_id_seq, upper(trim(p_hotel_name)), upper(trim(p_customer_name)),
            l_room_number, p_from_date, p_to_date);
    SET l_booked_room_count = l_booked_room_count + 1;
    IF l_booked_room_count = p_room_count THEN
      LEAVE rooms;
    END IF;
  END LOOP;
  CLOSE free_rooms;
  IF l_booked_room_count < p_room_count THEN
    SET p_message = concat('Unable to book ', p_room_count, ' rooms. Only ', l_booked_room_count, ' available. Nothing booked.');
    ROLLBACK;
  ELSE
    SET p_message = concat_ws('', 'Booked ', p_room_count, ' rooms.');
    COMMIT;
  END IF;
  OPEN BookingCursor FOR
    SELECT b.* FROM room_bookings b
     WHERE b.hotel_name = upper(trim(p_hotel_name))
       AND b.customer_name = upper(trim(p_customer_name))
       AND b.start_date = p_from_date
       AND b.end_date = p_to_date
     ORDER BY b.booking_id;
END */ //

-- ---------------------------------------------------------------- customer_portal
-- The customer comes from @mcp_customer_name and nowhere else; no routine takes a customer name.
CREATE FUNCTION customer_portal_current_customer() RETURNS varchar(4000) READS SQL DATA
BEGIN
  DECLARE l_name varchar(4000) DEFAULT nullif(upper(trim(@mcp_customer_name)), '');
  IF l_name IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20100,
      MESSAGE_TEXT = 'No customer. Connect with ?CUSTOMER_NAME=<your name> on the MCP server URL.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_name = l_name) THEN
    SET @mdb_msg = concat('Customer ', l_name, ' is not known to this hotel chain.');
    SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO = 20101, MESSAGE_TEXT = @mdb_msg;
  END IF;
  RETURN l_name;
END//

CREATE PROCEDURE customer_portal_my_details(OUT p_customer_name varchar(4000) /* oracle: VARCHAR2 */
                                           ,OUT p_phone_number  varchar(4000) /* oracle: VARCHAR2 */
                                           ,OUT p_email_address varchar(4000) /* oracle: VARCHAR2 */)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  SELECT customer_name, phone_number, email_address INTO p_customer_name, p_phone_number, p_email_address
    FROM customers WHERE customer_name = l_customer;
END//

CREATE PROCEDURE customer_portal_my_bookings(OUT p_bookings varchar(4000) /* oracle: BookingCursor */)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  SET p_bookings = 'BookingCursor substitute';
END//
/*M!120300 CREATE OR REPLACE PROCEDURE customer_portal_my_bookings(OUT p_bookings SYS_REFCURSOR)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  OPEN p_bookings FOR
    SELECT b.* FROM room_bookings b WHERE b.customer_name = l_customer ORDER BY b.start_date, b.booking_id;
END */ //

CREATE PROCEDURE customer_portal_book_rooms(IN  p_hotel_name varchar(4000) /* oracle: VARCHAR2 */
                                           ,IN  p_from_date  datetime /* oracle: DATE */
                                           ,IN  p_to_date    datetime /* oracle: DATE */
                                           ,IN  p_room_count int unsigned /* oracle: NATURAL */
                                           ,OUT p_bookings   varchar(4000) /* oracle: BookingCursor */
                                           ,OUT p_message    varchar(4000) /* oracle: VARCHAR2 */)
  CALL room_manager_bookroom(p_hotel_name, customer_portal_current_customer(), p_from_date, p_to_date,
                             p_room_count, p_bookings, p_message)//
/*M!120300 CREATE OR REPLACE PROCEDURE customer_portal_book_rooms(IN p_hotel_name varchar(4000)
                                                      ,IN p_from_date datetime
                                                      ,IN p_to_date datetime
                                                      ,IN p_room_count int unsigned
                                                      ,OUT p_bookings SYS_REFCURSOR
                                                      ,OUT p_message varchar(4000))
  CALL room_manager_bookroom(p_hotel_name, customer_portal_current_customer(), p_from_date, p_to_date,
                             p_room_count, p_bookings, p_message) */ //

CREATE PROCEDURE customer_portal_cancel_booking(IN  p_booking_id decimal(65,27) /* oracle: NUMBER */
                                               ,OUT p_message    varchar(4000) /* oracle: VARCHAR2 */)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  DECLARE l_id text DEFAULT trim(TRAILING '.' FROM trim(TRAILING '0' FROM p_booking_id));
  DELETE FROM room_bookings WHERE booking_id = p_booking_id AND customer_name = l_customer;
  IF row_count() = 0 THEN
    SET p_message = concat('You have no booking ', l_id, '.');
  ELSE
    SET p_message = concat('Cancelled booking ', l_id, '.');
    COMMIT;
  END IF;
END//

CREATE PROCEDURE customer_portal_my_complaints(OUT p_complaints varchar(4000) /* oracle: ComplaintCursor */)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  SET p_complaints = 'ComplaintCursor substitute';
END//
/*M!120300 CREATE OR REPLACE PROCEDURE customer_portal_my_complaints(OUT p_complaints SYS_REFCURSOR)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  OPEN p_complaints FOR
    SELECT c.* FROM complaints c WHERE c.customer_name = l_customer ORDER BY c.complaint_date, c.complaint_id;
END */ //

CREATE PROCEDURE customer_portal_add_complaint(IN  p_complaint_text varchar(4000) /* oracle: VARCHAR2 */
                                              ,OUT p_complaint_id   decimal(65,27) /* oracle: NUMBER */)
BEGIN
  DECLARE l_customer varchar(4000) DEFAULT customer_portal_current_customer();
  INSERT INTO complaints (customer_name, complaint_text) VALUES (l_customer, p_complaint_text);
  SET p_complaint_id = PREVIOUS VALUE FOR complaint_id_seq;
  COMMIT;
END//

DELIMITER ;
