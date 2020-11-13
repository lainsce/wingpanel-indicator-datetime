/*
 * Copyright (c) 2011-2019 elementary, Inc. (https://elementary.io)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace DateTime.Widgets {
    public class CalendarModel : Object {
        /* The data_range is the range of dates for which this model is storing
         * data.
         *
         * There is no way to set the ranges publicly. They can only be modified by
         * changing one of the following properties: month_start, num_weeks, and
         * week_starts_on.
         */
        public Util.DateRange data_range { get; private set; }

        /* The first day of the month */
        public GLib.DateTime month_start { get; set; }

        /* The number of weeks to show in this model */
        public int num_weeks { get; private set; default = 6; }

        /* The start of week, ie. Monday=1 or Sunday=7 */
        public GLib.DateWeekday week_starts_on { get; set; }

        public HashTable<E.Source, Gee.TreeMultiMap<string, ECal.Component>> source_events { get; private set; }

        /* Notifies when events are added, updated, or removed */
        public signal void events_added (E.Source source, Gee.Collection<ECal.Component> events);
        public signal void events_updated (E.Source source, Gee.Collection<ECal.Component> events);
        public signal void events_removed (E.Source source, Gee.Collection<ECal.Component> events);

        private E.SourceRegistry registry { get; private set; }
        private HashTable<string, ECal.Client> source_client;
        private HashTable<string, ECal.ClientView> source_view;

        private static CalendarModel? calendar_model = null;

        // Accessing the locale settings
        public Settings locale_settings;

        public static CalendarModel get_default () {
            lock (calendar_model) {
                if (calendar_model == null) {
                    calendar_model = new CalendarModel ();
                }
            }

            return calendar_model;
        }

        construct {
            open.begin ();

            // Accessing the locale settings
            locale_settings = new Settings ("io.elementary.switchboard.locale");

            source_client = new HashTable<string, ECal.Client> (str_hash, str_equal);
            source_events = new HashTable<E.Source, Gee.TreeMultiMap<string, ECal.Component> > (Util.source_hash_func, Util.source_equal_func);
            source_view = new HashTable<string, ECal.ClientView> (str_hash, str_equal);

            int week_start = Posix.NLTime.FIRST_WEEKDAY.to_string ().data[0];
            int week_start_user_pref = locale_settings.get_int ("first-day") + 1;
            if (week_start >= 1 && week_start <= 7) {
                if (week_start_user_pref == week_start) {
                    week_starts_on = (GLib.DateWeekday) (week_start - 1);
                } else {
                    print ("User Preference for week start: %i\nSystem Preference for week start: %i\n", week_start_user_pref, week_start);
                    week_starts_on = (GLib.DateWeekday) (week_start_user_pref - 1);
                }
            }

            month_start = Util.get_start_of_month ();
            compute_ranges ();
            notify["month-start"].connect (on_parameter_changed);
        }

        private async void open () {
            try {
                registry = yield new E.SourceRegistry (null);
                registry.source_removed.connect (remove_source);
                registry.source_added.connect ((source) => add_source_async.begin (source));

                // Add sources
                registry.list_sources (E.SOURCE_EXTENSION_CALENDAR).foreach ((source) => {
                    E.SourceCalendar cal = (E.SourceCalendar)source.get_extension (E.SOURCE_EXTENSION_CALENDAR);
                    if (cal.selected == true && source.enabled == true) {
                        add_source_async.begin (source);
                    }
                });

                load_all_sources ();
            } catch (GLib.Error error) {
                critical (error.message);
            }
        }

        private void load_all_sources () {
            lock (source_client) {
                foreach (var id in source_client.get_keys ()) {
                    var source = registry.ref_source (id);
                    E.SourceCalendar cal = (E.SourceCalendar)source.get_extension (E.SOURCE_EXTENSION_CALENDAR);

                    if (cal.selected == true && source.enabled == true) {
                        load_source (source);
                    }
                }
            }
        }

        private void remove_source (E.Source source) {
            debug ("Removing source '%s'", source.dup_display_name ());
            /* Already out of the model, so do nothing */
            unowned string uid = source.get_uid ();

            if (!source_view.contains (uid)) {
                return;
            }

            var current_view = source_view.get (uid);
            try {
                current_view.stop ();
            } catch (Error e) {
                warning (e.message);
            }

            source_view.remove (uid);
            lock (source_client) {
                source_client.remove (uid);
            }

            var events = source_events.get (source).get_values ().read_only_view;
            events_removed (source, events);
            source_events.remove (source);
        }

        public void change_month (int relative) {
            month_start = month_start.add_months (relative);
        }

        public void change_year (int relative) {
            month_start = month_start.add_years (relative);
        }

        /* --- Helper Methods ---// */

        private void compute_ranges () {
            var month_end = month_start.add_full (0, 1, -1);

            int dow = month_start.get_day_of_week ();
            int wso = (int)week_starts_on;
            int offset = 0;

            if (wso < dow) {
                offset = dow - wso;
            } else if (wso > dow) {
                offset = 7 + dow - wso;
            }

            var data_range_first = month_start.add_days (-offset);

            dow = month_end.get_day_of_week ();
            wso = (int)(week_starts_on + 6);

            /* WSO must be between 1 and 7 */
            if (wso > 7) {
                wso = wso - 7;
            }

            offset = 0;

            if (wso < dow) {
                offset = 7 + wso - dow;
            } else if (wso > dow) {
                offset = wso - dow;
            }

            var data_range_last = month_end.add_days (offset);

            data_range = new Util.DateRange (data_range_first, data_range_last);
            num_weeks = data_range.to_list ().size / 7;

            debug (@"Date ranges: ($data_range_first <= $month_start < $month_end <= $data_range_last)");
        }

        private void load_source (E.Source source) {
            /* create empty source-event map */
            var events = new Gee.TreeMultiMap<string, ECal.Component> (
                (GLib.CompareDataFunc<ECal.Component>?) GLib.strcmp,
                (GLib.CompareDataFunc<ECal.Component>?) Util.calcomponent_compare_func
            );
            source_events.set (source, events);
            /* query client view */
            var iso_first = ECal.isodate_from_time_t ((time_t)data_range.first_dt.to_unix ());
            var iso_last = ECal.isodate_from_time_t ((time_t)data_range.last_dt.add_days (1).to_unix ());
            var query = @"(occur-in-time-range? (make-time \"$iso_first\") (make-time \"$iso_last\"))";

            ECal.Client client;
            lock (source_client) {
                client = source_client.get (source.dup_uid ());
            }

            if (client == null) {
                return;
            }

            debug ("Getting client-view for source '%s'", source.dup_display_name ());
            client.get_view.begin (query, null, (obj, results) => {
                var view = on_client_view_received (results, source, client);
                view.objects_added.connect ((objects) => on_objects_added (source, client, objects));
                view.objects_removed.connect ((objects) => on_objects_removed (source, client, objects));
                view.objects_modified.connect ((objects) => on_objects_modified (source, client, objects));
                try {
                    view.start ();
                } catch (Error e) {
                    critical (e.message);
                }

                source_view.set (source.dup_uid (), view);
            });
        }

        private async void add_source_async (E.Source source) {
            debug ("Adding source '%s'", source.dup_display_name ());
            try {
                var client = (ECal.Client) ECal.Client.connect_sync (source, ECal.ClientSourceType.EVENTS, -1, null);
                source_client.insert (source.dup_uid (), client);
            } catch (Error e) {
                critical (e.message);
            }

            Idle.add (() => {
                load_source (source);

                return false;
            });
        }

        private void debug_event (E.Source source, ECal.Component event) {
            unowned ICal.Component comp = event.get_icalcomponent ();
            debug (@"Event ['$(comp.get_summary())', $(source.dup_display_name()), $(comp.get_uid()))]");
        }

        /* --- Signal Handlers ---// */
        private void on_parameter_changed () {
            compute_ranges ();
            load_all_sources ();
        }

        private ECal.ClientView on_client_view_received (AsyncResult results, E.Source source, ECal.Client client) {
            ECal.ClientView view;
            try {
                debug ("Received client-view for source '%s'", source.dup_display_name ());
                bool status = client.get_view.end (results, out view);
                assert (status == true);
            } catch (Error e) {
                critical ("Error loading client-view from source '%s': %s", source.dup_display_name (), e.message);
            }

            return view;
        }

#if E_CAL_2_0
        private void on_objects_added (E.Source source, ECal.Client client, SList<ICal.Component> objects) {
#else
        private void on_objects_added (E.Source source, ECal.Client client, SList<weak ICal.Component> objects) {
#endif
            debug (@"Received $(objects.length()) added event(s) for source '%s'", source.dup_display_name ());
            var events = source_events.get (source);
            var added_events = new Gee.ArrayList<ECal.Component> ((Gee.EqualDataFunc<ECal.Component>?) Util.calcomponent_equal_func);
            objects.foreach ((comp) => {
                unowned string uid = comp.get_uid ();
#if E_CAL_2_0
                client.generate_instances_for_object_sync (comp, (time_t) data_range.first_dt.to_unix (), (time_t) data_range.last_dt.to_unix (), null, (comp, start, end) => {
                    var event = new ECal.Component.from_icalcomponent (comp);
#else
                client.generate_instances_for_object_sync (comp, (time_t) data_range.first_dt.to_unix (), (time_t) data_range.last_dt.to_unix (), (event, start, end) => {
#endif
                    debug_event (source, event);
                    events.set (uid, event);
                    added_events.add (event);
                    return true;
                });
            });

            events_added (source, added_events.read_only_view);
        }

#if E_CAL_2_0
        private void on_objects_modified (E.Source source, ECal.Client client, SList<ICal.Component> objects) {
#else
        private void on_objects_modified (E.Source source, ECal.Client client, SList<weak ICal.Component> objects) {
#endif
            debug (@"Received $(objects.length()) modified event(s) for source '%s'", source.dup_display_name ());
            var updated_events = new Gee.ArrayList<ECal.Component> ((Gee.EqualDataFunc<ECal.Component>?) Util.calcomponent_equal_func);

            objects.foreach ((comp) => {
                unowned string uid = comp.get_uid ();
                var events = source_events.get (source).get (uid);
                updated_events.add_all (events);
                foreach (var event in events) {
                    debug_event (source, event);
                }
            });

            events_updated (source, updated_events.read_only_view);
        }

#if E_CAL_2_0
        private void on_objects_removed (E.Source source, ECal.Client client, SList<ECal.ComponentId?> cids) {
#else
        private void on_objects_removed (E.Source source, ECal.Client client, SList<weak ECal.ComponentId?> cids) {
#endif
            debug (@"Received $(cids.length()) removed event(s) for source '%s'", source.dup_display_name ());
            var events = source_events.get (source);
            var removed_events = new Gee.ArrayList<ECal.Component> ((Gee.EqualDataFunc<ECal.Component>?) Util.calcomponent_equal_func);

            cids.foreach ((cid) => {
                if (cid == null) {
                    return;
                }

                var comps = events.get (cid.get_uid ());
                foreach (ECal.Component event in comps) {
                    removed_events.add (event);
                    debug_event (source, event);
                }
            });

            events_removed (source, removed_events.read_only_view);
        }
    }
}
