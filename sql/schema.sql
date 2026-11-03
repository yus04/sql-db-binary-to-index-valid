-- dbo.Claims: クレーム情報 + 報告資料/添付資料 (VARBINARY) を 1 レコードで保持する
IF OBJECT_ID(N'dbo.Claims', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Claims (
        ClaimId         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Claims PRIMARY KEY,
        ClaimNumber     NVARCHAR(20)   NOT NULL, -- クレーム番号
        ReceivedDate    DATE           NOT NULL, -- 受付日
        CustomerName    NVARCHAR(100)  NOT NULL, -- 顧客名
        ProductName     NVARCHAR(100)  NOT NULL, -- 製品名
        LotNumber       NVARCHAR(50)   NULL,     -- 製造ロット
        ClaimCategory   NVARCHAR(50)   NOT NULL, -- クレーム区分
        Severity        NVARCHAR(10)   NOT NULL, -- 重要度
        IncidentDate    DATE           NULL,     -- 発生日
        IncidentSummary NVARCHAR(1000) NOT NULL, -- 発生事象
        Status          NVARCHAR(20)   NOT NULL, -- 対応状況
        DocumentType    NVARCHAR(20)   NOT NULL, -- 資料種別 (報告資料 / 添付資料)
        FileName        NVARCHAR(260)  NOT NULL, -- 元ファイル名
        ContentType     NVARCHAR(100)  NOT NULL, -- MIME タイプ
        FileData        VARBINARY(MAX) NOT NULL, -- ファイルの生データ
        CreatedAt       DATETIME2(3)   NOT NULL CONSTRAINT DF_Claims_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_Claims_ClaimNumber_FileName UNIQUE (ClaimNumber, FileName)
    );
END
GO

-- Azure Functions の SQL トリガーは変更の追跡 (Change Tracking) を利用する
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE CURRENT SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
GO

IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.Claims'))
    ALTER TABLE dbo.Claims ENABLE CHANGE_TRACKING;
GO
