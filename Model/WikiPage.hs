module Model.WikiPage
    ( getAllWikiComments
    ) where

import Import

import Model.Comment (exprPermissionFilter, exprUnapproved, makeViewerInfo)
import Model.Project (getProjectPages)
import Model.User    (isProjectModerator')

-- | Get the unapproved, new and old Comments on all WikiPages of Project. Takes a
-- UTCTime 'since' to filter comments EARLIER than this time, and a CommentId
-- 'latest_comment_id' to filter comments AFTER this comment (used for paging).
getAllWikiComments :: Maybe UserId -> ProjectId -> CommentId -> UTCTime -> Int64 -> YesodDB App ([Entity Comment], [Entity Comment], [Entity Comment])
getAllWikiComments mviewer_id project_id latest_comment_id since limit_num = do
    viewer_info         <- makeViewerInfo mviewer_id project_id
    pages_ids           <- map entityKey <$> getProjectPages project_id
    unapproved_comments <- getUnapprovedComments viewer_info pages_ids
    new_comments        <- getNewComments        viewer_info pages_ids
    old_comments        <- getOldComments        viewer_info pages_ids (limit_num - fromIntegral (length new_comments))
    return (unapproved_comments, new_comments, old_comments)
  where
    getUnapprovedComments :: Maybe (UserId, Bool) -> [WikiPageId] -> YesodDB App [Entity Comment]
    getUnapprovedComments viewer_info pages_ids =
        select $
        from $ \(c `InnerJoin` wp) -> do
        on_ (c ^. CommentDiscussion ==. wp ^. WikiPageDiscussion)
        where_ $
            wp ^. WikiPageId `in_` valList pages_ids &&.
            exprUnapproved c &&.
            exprPermissionFilter viewer_info c
        orderBy [desc (c ^. CommentCreatedTs)]
        return c

    getNewComments :: Maybe (UserId, Bool) -> [WikiPageId] -> YesodDB App [Entity Comment]
    getNewComments viewer_info pages_ids =
        select $
        from $ \(c `InnerJoin` wp) -> do
        on_ (c ^. CommentDiscussion ==. wp ^. WikiPageDiscussion)
        where_ $
            wp ^. WikiPageId `in_` valList pages_ids &&.
            c ^. CommentId <=. val latest_comment_id &&.
            c ^. CommentModeratedTs >=. just (val since) &&.
            exprPermissionFilter viewer_info c
        orderBy [desc (c ^. CommentModeratedTs)]
        limit limit_num
        return c

    getOldComments :: Maybe (UserId, Bool) -> [WikiPageId] -> Int64 -> YesodDB App [Entity Comment]
    getOldComments viewer_info pages_ids lim =
        select $
        from $ \(c `InnerJoin` wp) -> do
        on_ (c ^. CommentDiscussion ==. wp ^. WikiPageDiscussion)
        where_ $
            wp ^. WikiPageId `in_` valList pages_ids &&.
            c ^. CommentModeratedTs <. just (val since) &&.
            exprPermissionFilter viewer_info c
        orderBy [desc (c ^. CommentModeratedTs)]
        limit lim
        return c
