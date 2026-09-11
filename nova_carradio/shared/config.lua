NovaCarRadioConfig = {
    -- 'auto', 'nova', 'qbcore', 'esx', or 'standalone'.
    Framework = 'auto',
    Command = 'carradio',
    DriverOnly = false,
    AllowPassengers = true,
    DefaultVolume = 0.55,
    MaxVolume = 1.0,
    InsideGainBoost = 2.25,
    OutsideGainBoost = 1.0,
    OtherVehicleGainBoost = 0.90,
    MaxOliGain = 3.0,
    HearingDistance = 22.0,
    MaxUrlLength = 700,
    QueueLimit = 50,
    HistoryLimit = 20,
    FavoritesLimit = 40,
    PlaylistLimit = 20,
    PlaylistTrackLimit = 50,
    PlaylistBulkAddLimit = 20,
    VolumeStep = 0.05,
    MaxRequestPayloadBytes = 32768,
    MaxNearbyRadios = 8,
    UiUpdateMs = 250,
    SoundCloudUpdateMs = 180,
    DisableNativeRadio = true,

    SoundCloud = {
        Enabled = true,
        OutsideClosedMultiplier = 0.18,
        OutsideOpenMultiplier = 0.42,
        OtherVehicleMultiplier = 0.16,
    },

    Visualizer = {
        Bars = 32,
        Smoothing = 0.78,
        IdleFloor = 0.06,
        EmbeddedBassPulse = 0.92,
    },

    DJ = {
        Enabled = true,
        Default = { bass = 0, reverb = 0, distortion = 0, tempo = 1.0 },
        BassMinFrequency = 3200,
        BassMaxFrequency = 20000,
        TempoMin = 0.75,
        TempoMax = 1.25,
    },

    Database = {
        Enabled = true,
        AutoCreate = true,
    }
}
