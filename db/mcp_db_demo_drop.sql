-- mcp_db_demo_drop.sql: drops everything the DDL created, so the demo can be built again. Run it as
-- mcpdemo:
--
--   mariadb -h <host> -u mcpdemo -p mcpdemo < db/mcp_db_demo_drop.sql
--
-- The database and the login are left alone. To remove those too, as root:
--   DROP DATABASE mcpdemo; DROP USER 'mcpdemo'@'%';

DROP PROCEDURE IF EXISTS customer_portal_add_complaint;
DROP PROCEDURE IF EXISTS customer_portal_my_complaints;
DROP PROCEDURE IF EXISTS customer_portal_cancel_booking;
DROP PROCEDURE IF EXISTS customer_portal_book_rooms;
DROP PROCEDURE IF EXISTS customer_portal_my_bookings;
DROP PROCEDURE IF EXISTS customer_portal_my_details;
DROP FUNCTION IF EXISTS customer_portal_current_customer;
DROP PROCEDURE IF EXISTS room_manager_bookroom;
DROP PROCEDURE IF EXISTS room_manager_getroomlist;
DROP PROCEDURE IF EXISTS hotel_occupancy;
DROP PROCEDURE IF EXISTS upsert_customer;
DROP VIEW IF EXISTS hotel_amenities_summary;
DROP VIEW IF EXISTS hotel_regions;
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS complaints, room_bookings, customers, hotel_rooms, hotel_amenities, hotels;
SET FOREIGN_KEY_CHECKS = 1;
DROP SEQUENCE IF EXISTS booking_id_seq;
DROP SEQUENCE IF EXISTS complaint_id_seq;
